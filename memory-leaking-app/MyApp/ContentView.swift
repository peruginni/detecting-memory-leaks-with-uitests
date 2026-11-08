//
//  ContentView.swift
//  MyApp
//
//  Created for the sample project.
//

import SwiftUI
import Foundation
import Combine

struct ContentView: View {
    @State private var isDetailScreenPresented = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Memory Leaking App")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Open and close the leaking detail screen repeatedly while a memory tool watches the process.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button {
                isDetailScreenPresented = true
            } label: {
                Label("Open detail screen", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("open-detail-screen")
        }
        .padding()
        .sheet(isPresented: $isDetailScreenPresented) {
            DetailScreen {
                isDetailScreenPresented = false
            }
        }
    }
}

struct DetailScreen: View {
    let close: () -> Void
    @StateObject private var model = DetailScreenModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "drop.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)

                Text("This screen intentionally leaks")
                    .font(.headline)

                Text(model.generatedText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text("Payload: \(model.payloadSizeInKilobytes) KB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Detail Screen")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Close") {
                        close()
                    }
                    .accessibilityIdentifier("close-detail-screen")
                }
            }
            .accessibilityIdentifier("detail-screen")
        }
    }
}

final class DetailScreenModel: ObservableObject {
    @Published private(set) var generatedText = "The model owns a closure that retains the model."

    let payloadSizeInKilobytes = 512

    private let payload: Data
    private var retainCycle: (() -> Void)?

    init() {
        payload = Data(repeating: 0x2A, count: payloadSizeInKilobytes * 1024)

        retainCycle = { [self] in
            generatedText = "Still retained."
            _ = payload.count
        }
    }
}

#Preview {
    ContentView()
}
