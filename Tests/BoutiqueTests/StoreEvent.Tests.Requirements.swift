import Boutique
import Testing

extension Store {
    func validateStoreEvent(event: StoreEvent<BoutiqueItem>) throws {
        // Buffered events describe the state at publication, not the Store's
        // current items when the consumer eventually handles them.
        switch event.operation {
        case .initialized: try #require(event.items.isEmpty)
        case .insert: try #require(!event.items.isEmpty)
        case .loaded, .remove: break
        }
    }
}
