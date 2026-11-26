// Shows the picture a push names (fcm_options.image) as the notification's thumbnail; round for a private
// message (the sender's photo, Owner 26 Nov 2026). No picture, or any failure → the notification as it came.
// Added to the Xcode project on every build by tools/ios/add-notification-service.rb.
import UIKit
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var task: URLSessionDataTask?
    private let lock = NSLock()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        content = request.content.mutableCopy() as? UNMutableNotificationContent
        guard let options = request.content.userInfo["fcm_options"] as? [String: Any],
              let address = options["image"] as? String,
              let url = URL(string: address), url.scheme == "https" else {
            finish()
            return
        }
        let round = (request.content.userInfo["type"] as? String) == "new_message"
        var get = URLRequest(url: url)
        get.timeoutInterval = 8
        task = URLSession.shared.dataTask(with: get) { [weak self] data, response, _ in
            guard let self = self else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let data = data, data.count <= 3 * 1024 * 1024,
               let image = UIImage(data: data),
               let png = NotificationService.prepared(image, round: round).pngData() {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                if (try? png.write(to: file)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "photo", url: file, options: nil) {
                    self.content?.attachments = [attachment]
                }
            }
            self.finish()
        }
        task?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        finish()
    }

    /// Hand the notification back exactly once.
    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard let done = handler, let result = content else { return }
        handler = nil
        done(result)
    }

    /// Round: the middle square, cut to a circle, at most 300 px. Otherwise the picture, at most 1024 px wide.
    private static func prepared(_ image: UIImage, round: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        if round {
            let side = min(image.size.width, image.size.height)
            let out = min(side, 300)
            let ratio = out / side
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).image { _ in
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: out, height: out)).addClip()
                image.draw(in: CGRect(x: (out - size.width) / 2, y: (out - size.height) / 2,
                                      width: size.width, height: size.height))
            }
        }
        let width = min(image.size.width, 1024)
        let size = CGSize(width: width, height: image.size.height * (width / max(image.size.width, 1)))
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
