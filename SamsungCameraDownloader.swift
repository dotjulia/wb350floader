import SwiftUI
import Foundation
import AppKit
import Darwin

struct CameraFile: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let previewURL: URL?
    let size: Int
}

@MainActor
final class CameraModel: ObservableObject {
    @Published var cameraIP = ""
    @Published var status = "Enter the camera IP or discover it."
    @Published var files: [CameraFile] = []
    @Published var busy = false

    private var controlURL: URL?
    private let defaultSamsungIP = "192.168.107.1"

    func discover() {
        busy = true
        status = "Connecting to Samsung camera..."
        files = []
        Task {
            do {
                cameraIP = defaultSamsungIP
                try await connectSamsung(ip: defaultSamsungIP)
            } catch {
                status = "Connection failed: \(error.localizedDescription)."
                busy = false
            }
        }
    }

    func connectManually() {
        let enteredAddress = cameraIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredAddress.isEmpty else {
            status = "Enter an IP address first."
            return
        }
        let ip: String
        do {
            ip = try CameraAddress.host(from: enteredAddress)
        } catch {
            status = error.localizedDescription
            return
        }
        cameraIP = ip
        busy = true
        status = "Connecting to \(ip):7676..."
        files = []
        Task {
            do {
                try await connectSamsung(ip: ip)
            } catch {
                let nsError = error as NSError
                status = "Connection to \(ip):7676 failed: \(error.localizedDescription) [\(nsError.domain) \(Int32(nsError.code))]"
                busy = false
            }
        }
    }

    func save(_ file: CameraFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(for: file)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true
        status = "Downloading \(file.title)..."
        Task {
            do {
                let result = try await HTTP.request(url: file.url, method: "GET")
                guard (200..<300).contains(result.statusCode) else {
                    throw CameraError.httpStatus(result.statusCode, file.url)
                }
                try result.body.write(to: destination, options: .atomic)
                status = "Saved \(file.title)"
            } catch {
                status = "Download failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func downloadSelected(_ selectedFiles: [CameraFile]) {
        guard !selectedFiles.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        busy = true
        Task {
            var completed = 0
            do {
                for file in selectedFiles {
                    let result = try await HTTP.request(url: file.url, method: "GET")
                    guard (200..<300).contains(result.statusCode) else {
                        throw CameraError.httpStatus(result.statusCode, file.url)
                    }
                    try result.body.write(
                        to: folder.appendingPathComponent(filename(for: file)),
                        options: .atomic
                    )
                    completed += 1
                }
                status = "Downloaded \(completed) file(s)."
            } catch {
                status = "Downloaded \(completed) of \(selectedFiles.count) file(s). \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func filename(for file: CameraFile) -> String {
        let filename = URL(fileURLWithPath: file.title).lastPathComponent
        return filename.lowercased().hasSuffix(".jpg") ? filename : "\(filename).jpg"
    }

    private func connectSamsung(ip: String) async throws {
        guard let descriptionURL = URL(string: "http://\(ip):7676/smp_6_") else {
            throw CameraError.invalidResponse
        }
        let description = try await UPnP.description(at: descriptionURL)
        guard let service = description.services.first(where: { $0.type.contains("ContentDirectory") }),
              let control = URL(string: service.controlURL, relativeTo: descriptionURL)?.absoluteURL else {
            throw CameraError.noContentDirectory
        }
        let result = try await UPnP.browse(controlURL: control)
        finishSamsungConnection(ip: ip, name: description.name, control: control, files: result)
    }

    private func finishSamsungConnection(ip: String, name: String, control: URL, files: [CameraFile]) {
        cameraIP = ip
        controlURL = control
        self.files = files
        status = "Connected to \(name) at \(ip). \(files.count) file(s) found."
        busy = false
    }
}

enum CameraAddress {
    static func host(from value: String) throws -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://"), let url = URL(string: text), let host = url.host {
            text = host
        } else if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if let colon = text.lastIndex(of: ":"),
           text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            text = String(text[..<colon])
        }
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else {
            throw CameraError.invalidAddress
        }
        return text
    }
}

enum CameraError: LocalizedError {
    case notFound, noContentDirectory, invalidResponse, invalidAddress
    case hostResolutionFailed(String, String)
    case requestFailed(URL, String)
    case httpStatus(Int, URL)
    var errorDescription: String? {
        switch self {
        case .notFound: return "No camera was found."
        case .noContentDirectory: return "The device has no UPnP ContentDirectory service."
        case .invalidResponse: return "The camera returned an invalid response."
        case .invalidAddress: return "Enter the camera IPv4 address, for example 192.168.107.1."
        case .hostResolutionFailed(let host, let reason):
            return "Could not resolve \(host): \(reason)"
        case .requestFailed(let url, let reason):
            return "Request to \(url.absoluteString) failed: \(reason)"
        case .httpStatus(let status, let url):
            return "The camera returned HTTP \(status) for \(url.absoluteString)."
        }
    }
}

struct Service {
    let type: String
    let controlURL: String
}

struct DeviceDescription {
    let name: String
    let services: [Service]
}

struct CameraFolder {
    let id: String
    let title: String
}

struct BrowsePage {
    let files: [CameraFile]
    let folders: [CameraFolder]
}

enum UPnP {
    private static var samsungUserAgent: String {
        for interface in ["en0", "en1", "en2"] {
            let task = Process()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
            task.arguments = [interface]
            task.standardOutput = output
            try? task.run()
            task.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let pattern = "ether ([0-9a-fA-F:]{17})"
            if let range = text.range(of: pattern, options: .regularExpression) {
                let mac = String(text[range]).replacingOccurrences(of: "ether ", with: "")
                return "SEC_DSC_\(mac)"
            }
        }
        return "SEC_DSC_UNKNOWN"
    }

    static func description(at url: URL) async throws -> DeviceDescription {
        let result = try await HTTP.request(
            url: url,
            method: "GET",
            headers: [
                "User-Agent": samsungUserAgent,
                "Access-Method": "manual"
            ]
        )
        guard (200..<300).contains(result.statusCode) else {
            throw CameraError.httpStatus(result.statusCode, url)
        }
        let parser = DescriptionParser()
        parser.parse(result.body)
        guard let name = parser.name else { throw CameraError.invalidResponse }
        return DeviceDescription(name: name, services: parser.services)
    }

    static func browse(controlURL: URL) async throws -> [CameraFile] {
        var visited: Set<String> = []
        return try await browse(controlURL: controlURL, objectID: "0", path: "", visited: &visited)
    }

    private static func browse(
        controlURL: URL,
        objectID: String,
        path: String,
        visited: inout Set<String>
    ) async throws -> [CameraFile] {
        guard visited.insert(objectID).inserted else { return [] }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
          s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
          <ObjectID>\(objectID)</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>
          <Filter>*</Filter><StartingIndex>0</StartingIndex>
          <RequestedCount>500</RequestedCount><SortCriteria></SortCriteria>
          </u:Browse></s:Body>
        </s:Envelope>
        """
        let result = try await HTTP.request(
            url: controlURL,
            method: "POST",
            body: Data(body.utf8),
            headers: [
                "Content-Type": "text/xml; charset=\"utf-8\"",
                "SOAPAction": "\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"",
                "User-Agent": samsungUserAgent,
                "Access-Method": "manual"
            ]
        )
        guard (200..<300).contains(result.statusCode) else {
            throw CameraError.httpStatus(result.statusCode, controlURL)
        }
        let parser = BrowseParser(baseURL: controlURL)
        let page = parser.parseSOAP(result.body)
        var files = page.files.map { file in
            CameraFile(title: path.isEmpty ? file.title : "\(path)/\(file.title)",
                       url: file.url, previewURL: file.previewURL, size: file.size)
        }
        for folder in page.folders {
            let folderPath = path.isEmpty ? folder.title : "\(path)/\(folder.title)"
            files += try await browse(
                controlURL: controlURL,
                objectID: folder.id,
                path: folderPath,
                visited: &visited
            )
        }
        return files
    }
}

enum HTTP {
    struct Response {
        let statusCode: Int
        let body: Data
    }

    static func request(
        url: URL,
        method: String,
        body: Data = Data(),
        headers: [String: String] = [:]
    ) async throws -> Response {
        guard url.scheme?.lowercased() == "http", url.host != nil else {
            throw CameraError.invalidResponse
        }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try perform(url: url, method: method, body: body, headers: headers)
            } catch {
                lastError = error
                let nsError = error as NSError
                let retryable = nsError.domain == NSPOSIXErrorDomain
                    && [EHOSTUNREACH, ETIMEDOUT, ECONNREFUSED].contains(Int32(nsError.code))
                guard retryable, attempt < 2 else {
                    throw CameraError.requestFailed(url, error.localizedDescription)
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw CameraError.requestFailed(url, lastError?.localizedDescription ?? "unknown error")
    }

    fileprivate static func probe(url: URL, timeout: Int) throws -> Bool {
        let response = try perform(
            url: url,
            method: "GET",
            body: Data(),
            headers: [
                "User-Agent": "SEC_DSC_UNKNOWN",
                "Access-Method": "manual"
            ],
            timeout: timeout
        )
        return (200..<300).contains(response.statusCode)
    }

    fileprivate static func perform(
        url: URL,
        method: String,
        body: Data,
        headers: [String: String],
        timeout: Int = 15
    ) throws -> Response {
        guard let host = url.host else { throw CameraError.invalidResponse }
        let port = url.port ?? 80
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var addressInfo: UnsafeMutablePointer<addrinfo>?
        let addressResult = getaddrinfo(host, String(port), &hints, &addressInfo)
        guard addressResult == 0, let addressInfo else {
            let reason = String(cString: gai_strerror(addressResult))
            throw CameraError.hostResolutionFailed(host, reason)
        }
        defer { freeaddrinfo(addressInfo) }

        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        defer { close(socketFD) }
        var socketTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard Darwin.connect(socketFD, addressInfo.pointee.ai_addr, addressInfo.pointee.ai_addrlen) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }

        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: \(host):\(port)\r\nAccept: */*\r\nConnection: close\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        if !body.isEmpty { request += "Content-Length: \(body.count)\r\n" }
        request += "\r\n"
        var requestData = Data(request.utf8)
        requestData.append(body)
        try requestData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < requestData.count {
                let count = send(socketFD, baseAddress.advanced(by: sent), requestData.count - sent, 0)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
                sent += count
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(socketFD, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                throw POSIXError(POSIXErrorCode(rawValue: errno)!)
            }
            response.append(contentsOf: buffer[0..<count])
        }
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: response[..<separator.lowerBound], encoding: .utf8),
              let statusLine = header.components(separatedBy: "\r\n").first,
              let statusText = statusLine.split(separator: " ")[safe: 1],
              let statusCode = Int(statusText) else {
            throw CameraError.invalidResponse
        }
        return Response(statusCode: statusCode, body: response[separator.upperBound...])
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class DescriptionParser: NSObject, XMLParserDelegate {
    var name: String?
    var services: [Service] = []
    private var current = ""
    private var serviceType = ""
    private var controlURL = ""
    private var inService = false
    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        current = name
        if name == "service" { inService = true; serviceType = ""; controlURL = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inService || current == "friendlyName" else { return }
        if current == "friendlyName" { name = (name ?? "") + string }
        if current == "serviceType" { serviceType += string }
        if current == "controlURL" { controlURL += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "service" {
            services.append(Service(type: serviceType.trimmingCharacters(in: .whitespacesAndNewlines),
                                    controlURL: controlURL.trimmingCharacters(in: .whitespacesAndNewlines)))
            inService = false
        }
        current = ""
    }
}

final class BrowseParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    var files: [CameraFile] = []
    var folders: [CameraFolder] = []
    
    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parseSOAP(_ data: Data) -> BrowsePage {
        files = []
        folders = []
        let resultParser = SOAPResultParser()
        resultParser.parse(data)
        guard let didlData = resultParser.result.data(using: .utf8) else {
            return BrowsePage(files: files, folders: folders)
        }
        parseDIDL(didlData)
        return BrowsePage(files: files, folders: folders)
    }

    private func parseDIDL(_ data: Data) {
        let parser = DIDLParser(baseURL: baseURL)
        parser.parse(data)
        files = parser.files
        folders = parser.folders
    }
}

private final class SOAPResultParser: NSObject, XMLParserDelegate {
    var result = ""
    private var inResult = false

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if localName(name, qualifiedName: qName) == "Result" {
            inResult = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inResult {
            result += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if localName(name, qualifiedName: qName) == "Result" {
            inResult = false
        }
    }
}

private final class DIDLParser: NSObject, XMLParserDelegate {
    struct Resource {
        let url: URL
        let size: Int
        let protocolInfo: String
    }

    let baseURL: URL
    var files: [CameraFile] = []
    var folders: [CameraFolder] = []
    private var current = ""
    private var itemTitle = ""
    private var folderID = ""
    private var folderTitle = ""
    private var itemResources: [Resource] = []
    private var currentResourceURL = ""
    private var currentResourceSize = 0
    private var currentResourceProtocolInfo = ""
    private var inItem = false
    private var inFolder = false

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let element = localName(name, qualifiedName: qName)
        current = element
        switch element {
        case "item":
            inItem = true
            itemTitle = ""
            itemResources = []
        case "container":
            inFolder = true
            folderID = attributes["id"] ?? ""
            folderTitle = ""
        case "res":
            currentResourceURL = ""
            currentResourceSize = Int(attributes["size"] ?? "") ?? 0
            currentResourceProtocolInfo = attributes["protocolInfo"] ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem && current == "title" {
            itemTitle += string
        } else if inFolder && current == "title" {
            folderTitle += string
        } else if inItem && current == "res" {
            currentResourceURL += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = localName(name, qualifiedName: qualifiedName)
        switch element {
        case "res":
            let value = currentResourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: value, relativeTo: baseURL)?.absoluteURL, !value.isEmpty {
                itemResources.append(Resource(url: url, size: currentResourceSize,
                                              protocolInfo: currentResourceProtocolInfo))
            }
        case "container":
            let trimmedTitle = folderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !folderID.isEmpty, !trimmedTitle.isEmpty {
                folders.append(CameraFolder(id: folderID, title: trimmedTitle))
            }
            inFolder = false
        case "item":
            let thumbnailMarkers = ["JPEG_TN", "JPEG_SM", "PNG_TN", "PNG_SM", "_TN", "_SM"]
            let fullResources = itemResources.filter { resource in
                !thumbnailMarkers.contains { resource.protocolInfo.contains($0) }
            }
            let candidates = fullResources.isEmpty ? itemResources : fullResources
            if let resource = candidates.max(by: { $0.size < $1.size }) {
                let title = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let previewURL = itemResources.first(where: { resource in
                    thumbnailMarkers.contains { resource.protocolInfo.contains($0) }
                })?.url
                files.append(CameraFile(title: title.isEmpty ? "Untitled" : title,
                                        url: resource.url,
                                        previewURL: previewURL ?? resource.url,
                                        size: resource.size))
            }
            inItem = false
        default:
            break
        }
        current = ""
    }
}

private func localName(_ name: String, qualifiedName: String?) -> String {
    let value = qualifiedName ?? name
    return value.split(separator: ":").last.map(String.init) ?? value
}

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @State private var selectedFileIDs: Set<CameraFile.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Camera IP address", text: $model.cameraIP)
                    .textFieldStyle(.roundedBorder)
                Button("Connect", action: model.connectManually)
                Button("Discover", action: model.discover)
                Button("Download Selected") {
                    let selectedFiles = model.files.filter { selectedFileIDs.contains($0.id) }
                    model.downloadSelected(selectedFiles)
                }
                .disabled(selectedFileIDs.isEmpty)
            }
            HStack {
                Text(model.status).foregroundStyle(.secondary)
                Spacer()
                if !selectedFileIDs.isEmpty {
                    Text("\(selectedFileIDs.count) selected")
                        .foregroundStyle(.secondary)
                }
            }
            List(model.files, selection: $selectedFileIDs) { file in
                HStack {
                    ImagePreview(url: file.previewURL)
                    Text(file.title)
                    Spacer()
                    Text(file.size > 0 ? "\(file.size / 1024) KB" : "")
                        .foregroundStyle(.secondary)
                    Button("Save") { model.save(file) }
                }
            }
            .frame(minWidth: 620, minHeight: 360)
        }
        .padding()
        .disabled(model.busy)
    }
}

struct ImagePreview: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            guard let url else {
                failed = true
                return
            }
            do {
                let result = try await HTTP.request(url: url, method: "GET")
                guard (200..<300).contains(result.statusCode),
                      let loadedImage = NSImage(data: result.body) else {
                    failed = true
                    return
                }
                image = loadedImage
            } catch {
                failed = true
            }
        }
    }
}

@main
struct SamsungCameraDownloaderApp: App {
    var body: some Scene {
        WindowGroup("Samsung Camera Downloader") {
            ContentView()
        }
    }
}
