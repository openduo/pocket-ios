// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import CoreLocation
import MapKit
import SwiftUI

/// A place for the composer: the map opens on the current location, the pin is the map's centre,
/// and a search moves it. The choice becomes a line of text, the address and its coordinates, so
/// the message carries it without a new wire field.
struct LocationPicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locator = Locator()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    /// What the map shows; a search looks around it first.
    @State private var region: MKCoordinateRegion?
    @State private var place: Place?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var resolving: Task<Void, Never>?

    struct Place {
        var name: String?
        var address: String?
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera) { UserAnnotation() }
                    .mapControls { MapUserLocationButton() }
                    .onMapCameraChange(frequency: .onEnd) { ctx in
                        center = ctx.region.center
                        region = ctx.region
                        resolve(ctx.region.center)
                    }
                // The pin is the map's centre: drag the map under it.
                Image(systemName: "mappin")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Palette.brand)
                    .offset(y: -17)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if !results.isEmpty { resultList }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle(String(localized: "位置"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "搜索地点"))
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { _, q in if q.isEmpty { results = [] } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
        .onAppear { locator.request() }
    }

    private var resultList: some View {
        List(results, id: \.self) { item in
            Button {
                results = []
                query = ""
                place = Self.place(of: item)
                camera = .item(item)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "").foregroundStyle(Palette.text)
                    if let a = Self.address(of: item) {
                        Text(a).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if locator.denied {
                Text(String(localized: "定位权限已关闭，可以在设置里打开，或者拖动地图选点。"))
                    .font(.footnote).foregroundStyle(Palette.attention)
            }
            Text(place?.name ?? place?.address ?? (center == nil ? String(localized: "正在定位…") : String(localized: "地图中心")))
                .font(.headline).foregroundStyle(Palette.text).lineLimit(1)
            if let a = place?.address, place?.name != nil {
                Text(a).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            Button(String(localized: "使用这个位置")) {
                guard let c = center else { return }
                onPick(text(c))
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(center == nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    /// The line inserted into the draft. The coordinates are Apple Maps' own: GCJ-02 where the map
    /// data comes from a Chinese provider (measured in Beijing and Hong Kong), WGS-84 elsewhere,
    /// with nothing reliable saying which. They are labelled as map coordinates, not a datum.
    private func text(_ c: CLLocationCoordinate2D) -> String {
        let label = [place?.name, place?.address].compactMap { $0 }.reduce(into: [String]()) { out, s in
            if !out.contains(where: { $0.contains(s) || s.contains($0) }) { out.append(s) }
        }.joined(separator: String(localized: "，"))
        // Five decimals is about a metre. Display only.
        let coords = String(format: "%.5f, %.5f", c.latitude, c.longitude)
        // Only the device's own fix is approximate; a point picked on the map is where it is.
        let rough = locator.reduced && camera.followsUserLocation
        var s = "📍 " + label + String(localized: "（\(String(localized: "地图坐标"))：\(coords)）")
        if rough { s += String(localized: "，大致位置") }
        return s
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let region { request.region = region }
        Task {
            let found = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
            results = found
        }
    }

    /// Names the point under the pin once the map stops; a newer stop cancels the older lookup.
    private func resolve(_ c: CLLocationCoordinate2D) {
        resolving?.cancel()
        resolving = Task {
            let p = await Self.reverseGeocode(c)
            if !Task.isCancelled { place = p }
        }
    }

    private static func reverseGeocode(_ c: CLLocationCoordinate2D) async -> Place? {
        guard let n = await ReverseGeocoder.name(CLLocation(latitude: c.latitude, longitude: c.longitude)) else { return nil }
        return Place(name: n.name, address: n.address)
    }

    private static func place(of item: MKMapItem) -> Place {
        Place(name: item.name, address: address(of: item))
    }

    private static func address(of item: MKMapItem) -> String? { ReverseGeocoder.address(of: item) }
}

/// When-in-use location permission and whether the user allowed only an approximate fix.
@Observable
final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var reduced = false
    private(set) var denied = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        update()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { update() }

    private func update() {
        let s = manager.authorizationStatus
        denied = s == .denied || s == .restricted
        reduced = manager.accuracyAuthorization == .reducedAccuracy
    }
}
