#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Records a `$screen` view each time this view appears.
    func lucidaScreen(_ name: String, client: LucidaClient, properties: Props = [:]) -> some View {
        onAppear { client.screen(name, properties) }
    }
}
#endif
