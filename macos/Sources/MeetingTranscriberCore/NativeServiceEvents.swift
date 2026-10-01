import Foundation

extension NativeService {
    func publish<T: Encodable>(_ name: RealtimeEventName, _ payload: T) {
        eventHub.publish(RealtimeMessage(name: name, payload: try? JSONEncoder().encode(payload)))
    }

    func publish(_ name: RealtimeEventName, _ payload: [String: Any]) {
        eventHub.publish(RealtimeMessage(
            name: name,
            payload: try? JSONSerialization.data(withJSONObject: payload)
        ))
    }
}
