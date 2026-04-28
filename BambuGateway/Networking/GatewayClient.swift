import Foundation

enum GatewayClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(String)
    case decodeError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid gateway URL."
        case .invalidResponse:
            return "Unexpected server response."
        case .serverError(let detail):
            return detail
        case .decodeError:
            return "Failed to parse server response."
        }
    }
}

struct PrintSubmission {
    let file: Imported3MFFile
    let printerId: String
    let plateId: Int?
    let plateType: String
    let machineProfile: String
    let processProfile: String
    let filamentOverrides: [Int: FilamentOverrideSelection]
}

struct GatewayClient {
    let baseURLString: String
    let session: URLSession
    let transferService: BackgroundTransferService?

    init(
        baseURLString: String,
        session: URLSession = .shared,
        transferService: BackgroundTransferService? = nil
    ) {
        self.baseURLString = baseURLString
        self.session = session
        self.transferService = transferService
    }

    func fetchPrinters() async throws -> [PrinterStatus] {
        let response: PrinterListResponse = try await get(path: "/api/printers")
        return response.printers
    }

    func fetchAMS() async throws -> AMSResponse {
        try await get(path: "/api/ams")
    }

    func fetchSlicerMachines() async throws -> [SlicerProfile] {
        try await get(path: "/api/slicer/machines")
    }

    func fetchSlicerProcesses(machine: String) async throws -> [SlicerProfile] {
        let query: [URLQueryItem] = machine.isEmpty ? [] : [URLQueryItem(name: "machine", value: machine)]
        return try await get(path: "/api/slicer/processes", queryItems: query)
    }

    func fetchSlicerFilaments(machine: String) async throws -> [SlicerProfile] {
        let query: [URLQueryItem] = machine.isEmpty ? [] : [URLQueryItem(name: "machine", value: machine)]
        return try await get(path: "/api/slicer/filaments", queryItems: query)
    }

    func fetchSlicerPlateTypes() async throws -> [PlateTypeOption] {
        try await get(path: "/api/slicer/plate-types")
    }

    func parse3MF(file: Imported3MFFile) async throws -> ThreeMFInfo {
        var form = MultipartFormData()
        form.addFile(name: "file", fileName: file.fileName, mimeType: "application/octet-stream", data: file.data)
        form.finalize()

        let (data, _) = try await request(
            path: "/api/parse-3mf",
            method: "POST",
            body: form.body,
            contentType: "multipart/form-data; boundary=\(form.boundary)"
        )

        return try decode(ThreeMFInfo.self, from: data)
    }

    func fetchFilamentMatches(printerId: String, filaments: [ProjectFilament]) async throws -> FilamentMatchResponse {
        let payload = FilamentMatchRequest(printerId: printerId, filaments: filaments)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(payload)

        let (data, _) = try await request(
            path: "/api/filament-matches",
            method: "POST",
            body: body,
            contentType: "application/json"
        )

        return try decode(FilamentMatchResponse.self, from: data)
    }

    func fetchPrintPreview(_ submission: PrintSubmission) async throws -> PreviewResult {
        guard let transferService else {
            throw GatewayClientError.serverError("Background transfer service is not available.")
        }

        var form = MultipartFormData()
        form.addFile(name: "file", fileName: submission.file.fileName, mimeType: "application/octet-stream", data: submission.file.data)

        if !submission.printerId.isEmpty {
            form.addField(name: "printer_id", value: submission.printerId)
        }
        if !submission.machineProfile.isEmpty {
            form.addField(name: "machine_profile", value: submission.machineProfile)
        }
        if !submission.processProfile.isEmpty {
            form.addField(name: "process_profile", value: submission.processProfile)
        }
        if let plateId = submission.plateId {
            form.addField(name: "plate_id", value: String(plateId))
        }
        if !submission.plateType.isEmpty {
            form.addField(name: "plate_type", value: submission.plateType)
        }
        if !submission.filamentOverrides.isEmpty {
            try addFilamentProfilesField(to: &form, overrides: submission.filamentOverrides)
        }
        form.finalize()

        let bodyURL = try form.writeBody(toTemporaryFileNamed: "print-preview")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: try resolveURL(path: "/api/print-preview"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await transferService.upload(request: request, fromFile: bodyURL)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(httpResponse, data: data)
        }

        guard let previewId = httpResponse.value(forHTTPHeaderField: "X-Preview-Id"),
              !previewId.isEmpty else {
            throw GatewayClientError.serverError("Server did not return a preview ID.")
        }

        let fileName = parseContentDispositionFilename(httpResponse) ?? submission.file.fileName
        let estimateHeader = httpResponse.value(forHTTPHeaderField: "X-Print-Estimate")
        let estimate = PrintEstimate.decodeFromHeader(estimateHeader)

        return PreviewResult(threeMFData: data, previewId: previewId, fileName: fileName, estimate: estimate)
    }

    func printFromPreview(previewId: String, printerId: String) async throws -> PrintResponse {
        var form = MultipartFormData()
        form.addField(name: "preview_id", value: previewId)
        if !printerId.isEmpty {
            form.addField(name: "printer_id", value: printerId)
        }
        form.finalize()

        let (data, _) = try await request(
            path: "/api/print",
            method: "POST",
            body: form.body,
            contentType: "multipart/form-data; boundary=\(form.boundary)",
            timeout: 600
        )

        return try decode(PrintResponse.self, from: data)
    }

    /// Submit a slice job (auto_print=false). Returns the job id.
    func createSliceJob(_ submission: PrintSubmission) async throws -> String {
        guard let transferService else {
            throw GatewayClientError.serverError("Background transfer service is not available.")
        }

        var form = MultipartFormData()
        form.addFile(name: "file", fileName: submission.file.fileName, mimeType: "application/octet-stream", data: submission.file.data)

        if !submission.printerId.isEmpty {
            form.addField(name: "printer_id", value: submission.printerId)
        }
        if !submission.machineProfile.isEmpty {
            form.addField(name: "machine_profile", value: submission.machineProfile)
        }
        if !submission.processProfile.isEmpty {
            form.addField(name: "process_profile", value: submission.processProfile)
        }
        if let plateId = submission.plateId {
            form.addField(name: "plate_id", value: String(plateId))
        }
        if !submission.plateType.isEmpty {
            form.addField(name: "plate_type", value: submission.plateType)
        }
        if !submission.filamentOverrides.isEmpty {
            try addFilamentProfilesField(to: &form, overrides: submission.filamentOverrides)
        }
        // auto_print stays false; the iOS app drives the print explicitly later.
        form.addField(name: "auto_print", value: "false")
        form.finalize()

        let bodyURL = try form.writeBody(toTemporaryFileNamed: "slice-job-create")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: try resolveURL(path: "/api/slice-jobs"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await transferService.upload(request: request, fromFile: bodyURL)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(httpResponse, data: data)
        }

        let response = try decode(SliceJob.self, from: data)
        return response.jobId
    }

    func fetchSliceJob(jobId: String) async throws -> SliceJob {
        try await get(path: "/api/slice-jobs/\(jobId)")
    }

    func cancelSliceJob(jobId: String) async throws {
        _ = try await request(
            path: "/api/slice-jobs/\(jobId)/cancel",
            method: "POST"
        )
    }

    /// Download the sliced 3MF for a job that has reached `ready`/`printing`.
    func fetchSliceJobOutput(jobId: String, fallbackFileName: String) async throws -> PreviewResult {
        let (data, response) = try await request(
            path: "/api/slice-jobs/\(jobId)/output",
            method: "GET",
            timeout: 120
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayClientError.invalidResponse
        }
        let fileName = parseContentDispositionFilename(httpResponse) ?? fallbackFileName
        let estimate = PrintEstimate.decodeFromHeader(
            httpResponse.value(forHTTPHeaderField: "X-Print-Estimate")
        )
        return PreviewResult(
            threeMFData: data,
            previewId: jobId,
            fileName: fileName,
            estimate: estimate
        )
    }

    /// Trigger a print from a `ready` slice job.
    func printFromJob(jobId: String, printerId: String) async throws -> PrintResponse {
        var form = MultipartFormData()
        form.addField(name: "job_id", value: jobId)
        if !printerId.isEmpty {
            form.addField(name: "printer_id", value: printerId)
        }
        form.finalize()

        let (data, _) = try await request(
            path: "/api/print",
            method: "POST",
            body: form.body,
            contentType: "multipart/form-data; boundary=\(form.boundary)",
            timeout: 600
        )

        return try decode(PrintResponse.self, from: data)
    }

    func submitPrint(_ submission: PrintSubmission) async throws -> PrintResponse {
        guard let transferService else {
            throw GatewayClientError.serverError("Background transfer service is not available.")
        }

        var form = MultipartFormData()
        form.addFile(name: "file", fileName: submission.file.fileName, mimeType: "application/octet-stream", data: submission.file.data)

        if !submission.printerId.isEmpty {
            form.addField(name: "printer_id", value: submission.printerId)
        }
        if let plateId = submission.plateId {
            form.addField(name: "plate_id", value: String(plateId))
        }
        if !submission.plateType.isEmpty {
            form.addField(name: "plate_type", value: submission.plateType)
        }
        if !submission.machineProfile.isEmpty {
            form.addField(name: "machine_profile", value: submission.machineProfile)
        }
        if !submission.processProfile.isEmpty {
            form.addField(name: "process_profile", value: submission.processProfile)
        }
        if !submission.filamentOverrides.isEmpty {
            try addFilamentProfilesField(to: &form, overrides: submission.filamentOverrides)
        }
        form.finalize()

        let bodyURL = try form.writeBody(toTemporaryFileNamed: "print")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: try resolveURL(path: "/api/print"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await transferService.upload(request: request, fromFile: bodyURL)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(httpResponse, data: data)
        }

        return try decode(PrintResponse.self, from: data)
    }

    func fetchUploadProgress(uploadId: String) async throws -> UploadProgressResponse {
        try await get(path: "/api/uploads/\(uploadId)")
    }

    func fetchCapabilities() async throws -> GatewayCapabilities {
        try await get(path: "/api/capabilities")
    }

    func registerDevice(_ payload: DeviceRegisterPayload) async throws {
        let body = try JSONEncoder().encode(payload)
        _ = try await request(
            path: "/api/devices/register",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    func unregisterDevice(id: String) async throws {
        _ = try await request(path: "/api/devices/\(id)", method: "DELETE")
    }

    func registerActivity(
        deviceId: String,
        payload: ActivityRegisterPayload
    ) async throws {
        let body = try JSONEncoder().encode(payload)
        _ = try await request(
            path: "/api/devices/\(deviceId)/activities",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    func unregisterActivity(
        deviceId: String,
        printerId: String
    ) async throws {
        _ = try await request(
            path: "/api/devices/\(deviceId)/activities/\(printerId)",
            method: "DELETE"
        )
    }

    func cancelUpload(uploadId: String) async throws {
        _ = try await request(path: "/api/uploads/\(uploadId)/cancel", method: "POST")
    }

    func setSpeed(printerId: String, level: SpeedLevel) async throws {
        let body = try JSONEncoder().encode(["level": level.rawValue])
        let (_, _) = try await request(
            path: "/api/printers/\(printerId)/speed",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    func setLight(printerId: String, node: String = "chamber_light", on: Bool) async throws {
        struct Payload: Encodable {
            let node: String
            let on: Bool
        }
        let body = try JSONEncoder().encode(Payload(node: node, on: on))
        _ = try await request(
            path: "/api/printers/\(printerId)/light",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    @discardableResult
    func pausePrint(printerId: String) async throws -> CommandResponse {
        let (data, _) = try await request(path: "/api/printers/\(printerId)/pause", method: "POST")
        return try decode(CommandResponse.self, from: data)
    }

    @discardableResult
    func resumePrint(printerId: String) async throws -> CommandResponse {
        let (data, _) = try await request(path: "/api/printers/\(printerId)/resume", method: "POST")
        return try decode(CommandResponse.self, from: data)
    }

    @discardableResult
    func cancelPrint(printerId: String) async throws -> CommandResponse {
        let (data, _) = try await request(path: "/api/printers/\(printerId)/cancel", method: "POST")
        return try decode(CommandResponse.self, from: data)
    }

    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await request(path: path, method: "GET", queryItems: queryItems)
        return try decode(T.self, from: data)
    }

    private func resolveURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host,
              !host.isEmpty else {
            throw GatewayClientError.invalidURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw GatewayClientError.invalidURL
        }
        return url
    }

    private func mapHTTPError(_ response: HTTPURLResponse, data: Data) -> GatewayClientError {
        if let detail = try? JSONDecoder().decode(ErrorDetailResponse.self, from: data).detail {
            return .serverError(detail)
        }
        return .serverError("Request failed with HTTP \(response.statusCode).")
    }

    private func request(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 60
    ) async throws -> (Data, URLResponse) {
        let url = try resolveURL(path: path, queryItems: queryItems)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GatewayClientError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            throw mapHTTPError(http, data: data)
        }

        return (data, response)
    }

    private func parseContentDispositionFilename(_ response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        // Parse filename="value" from Content-Disposition header
        let pattern = "filename=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else {
            return nil
        }
        return String(header[range])
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GatewayClientError.decodeError
        }
    }

    private func addFilamentProfilesField(
        to form: inout MultipartFormData,
        overrides: [Int: FilamentOverrideSelection]
    ) throws {
        let payload = Dictionary(
            uniqueKeysWithValues: overrides.map { (String($0.key), $0.value) }
        )
        let json = try JSONEncoder().encode(payload)
        if let string = String(data: json, encoding: .utf8) {
            form.addField(name: "filament_profiles", value: string)
        }
    }
}
