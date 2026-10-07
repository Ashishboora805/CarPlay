import LumenKit
import SwiftUI
import UIKit
import WebKit

struct BrowserView: View {
    @Environment(BrowserManager.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var addressText = ""
    @State private var showingTabs = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let tab = browser.selectedTab {
                progressBar(tab)
                ZStack {
                    WebViewContainer(tab: tab)
                    if let error = tab.error {
                        StateMessageView(error: error) { tab.reload() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.background)
                    }
                }
            } else {
                StateMessageView(systemImage: "globe", title: "No open tabs",
                                 message: "Search the web or enter an address.",
                                 actionTitle: "New Tab") { browser.newTab() }
                    .frame(maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingTabs) {
            TabsSheet()
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            if browser.tabs.isEmpty { browser.newTab() }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        let tab = browser.selectedTab
        return HStack(spacing: 4) {
            if !addressFocused {
                toolbarButton("chevron.left", label: "Back", enabled: tab?.canGoBack == true) { tab?.goBack() }
                toolbarButton("chevron.right", label: "Forward", enabled: tab?.canGoForward == true) { tab?.goForward() }
                if tab?.isLoading == true {
                    toolbarButton("xmark", label: "Stop", enabled: true) { tab?.stopLoading() }
                } else {
                    toolbarButton("arrow.clockwise", label: "Reload", enabled: tab != nil) { tab?.reload() }
                }
            }

            addressField(tab)

            if addressFocused {
                Button("Cancel") { addressFocused = false }
                    .padding(.horizontal, 4)
            } else {
                toolbarButton("house", label: "Home", enabled: true) { browser.goHome() }
                Button {
                    showingTabs = true
                } label: {
                    Text("\(browser.tabs.count)")
                        .font(.caption.weight(.bold))
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Tabs, \(browser.tabs.count) open")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .lumenAnimation(value: addressFocused)
    }

    private func addressField(_ tab: BrowserTab?) -> some View {
        HStack(spacing: 6) {
            if !addressFocused, let tab, tab.url != nil {
                Image(systemName: tab.isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(tab.isSecure ? Color.secondary : Color.orange)
                    .accessibilityLabel(tab.isSecure ? "Secure connection" : "Not secure")
            } else {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            TextField("Search \(settings.searchEngine.displayName) or enter address", text: $addressText)
                .textFieldStyle(.plain)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    browser.submit(addressText)
                    addressFocused = false
                }
                .accessibilityLabel("Address")
            if addressFocused, !addressText.isEmpty {
                Button { addressText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .cardStyle(cornerRadius: 10)
        .onChange(of: addressFocused) { _, focused in
            addressText = focused ? (tab?.url?.absoluteString ?? "") : (tab?.displayHost ?? "")
        }
        .onChange(of: tab?.url) { _, _ in
            if !addressFocused { addressText = tab?.displayHost ?? "" }
        }
        .onAppear { addressText = tab?.displayHost ?? "" }
    }

    private func toolbarButton(_ systemImage: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 36, height: 40)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func progressBar(_ tab: BrowserTab) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.border)
            if tab.isLoading {
                GeometryReader { proxy in
                    Rectangle().fill(.tint).frame(width: proxy.size.width * tab.progress)
                }
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// Displays the selected tab's WKWebView, swapping it when the tab changes.
struct WebViewContainer: UIViewRepresentable {
    let tab: BrowserTab

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let webView = tab.webView
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

private struct TabsSheet: View {
    @Environment(BrowserManager.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.tabs) { tab in
                    Button {
                        browser.select(tab.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title).lineLimit(1)
                                Text(tab.displayHost).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if tab.id == browser.selectedTab?.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                    .accessibilityLabel("Current tab")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    offsets.map { browser.tabs[$0].id }.forEach(browser.close)
                }
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close All", role: .destructive) { browser.closeAll() }
                        .disabled(browser.tabs.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        browser.newTab()
                        dismiss()
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                }
            }
        }
    }
}
