import Foundation

struct MultipartFormData {
    private(set) var boundary: String = "Boundary-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    mutating func finalize() {
        append("--\(boundary)--\r\n")
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
