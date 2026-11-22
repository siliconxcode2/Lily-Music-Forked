import SwiftUI
import YTMCore

struct PageHeaderView: View {
    let header: PageHeader
    let canPlay: Bool
    let canShuffle: Bool
    let canRadio: Bool
    /// The navigation bar's height, which a banner reaches up under.
    let topInset: CGFloat
    /// Under iPhone Duo's column of tabs; nowhere else, where it would
    /// mirror the banner up into the space a pull to refresh opens.
    let extendsBanner: Bool
    let download: DownloadButton?
    /// The page's address, which a menu at the end of the buttons copies.
    let link: String?
    /// The page from YouTube, which saves and subscribes; nil for one held on the device.
    let model: PageModel?
    /// Opens the rename or delete dialog of the account's own playlist; nil for any other page.
    let edit: ((PlaylistDialog) -> Void)?
    let perform: (HeaderAction) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// The banner's secondary text goes solid, as iOS's translucent text does.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The page samples its tint at this size too, so the decode is shared.
    static func artEdge(_ header: PageHeader, topInset: CGFloat) -> CGFloat {
        header.banner ? Metrics.bannerHeight + topInset : Metrics.headerArt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if header.banner {
                let height = Self.artEdge(header, topInset: topInset)
                ZStack(alignment: .bottomLeading) {
                    ZStack {
                        ArtworkImage(url: header.thumbnail, edge: height, placeholder: false)
                            .frame(height: height)
                            .clipped()
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.35), .init(color: theme.bannerShade, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .backgroundExtensionEffect(isEnabled: extendsBanner)
                    // A banner is darkened behind its text, which stays white in every look.
                    HeaderText(header: header, foreground: theme.onColour, secondary: reduceTransparency ? theme.onColour : theme.onColour.opacity(0.7))
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.bottom, 24)
                }
                .frame(height: height)
                .padding(.top, -topInset)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if header.thumbnail != nil || canPlay {
                        ArtworkView(
                            url: header.thumbnail, size: Self.artEdge(header, topInset: topInset), radius: Metrics.cardArtRadius,
                            shadow: (theme.shadowDeep, 20, 8)
                        )
                            .frame(maxWidth: .infinity)
                    }
                    HeaderText(header: header, foreground: theme.text, secondary: theme.textSecondary)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }

            if canPlay || canRadio || link != nil || canSave || canSubscribe {
                // Closer together where they would run off the screen, as an artist's or a saved playlist's can.
                ViewThatFits(in: .horizontal) {
                    actions(spacing: 20)
                    actions(spacing: 8)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .frame(height: Metrics.actionsHeight)
            }
        }
    }

    private var canSave: Bool {
        model != nil && header.saved != nil && header.playlistId != nil && header.editable != true
    }

    private var canSubscribe: Bool {
        model != nil && header.subscribed != nil && header.channelId != nil
    }

    /// On glass, in one container, so neighbouring buttons blend and each menu grows out of its button.
    private func actions(spacing: CGFloat) -> some View {
        GlassEffectContainer(spacing: spacing) {
            actionButtons(spacing: spacing)
        }
    }

    private func actionButtons(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if canPlay {
                PlayButton(size: 56) { perform(.play) }
            }
            if canShuffle {
                IconButton(icon: .shuffle, size: 48, iconSize: 22, colour: theme.text, glass: true, feedback: .impact(weight: .light)) { perform(.shuffle) }
                    .accessibilityLabel("Shuffle")
            }
            if canRadio {
                IconButton(icon: .radio, size: 48, iconSize: 22, colour: theme.text, glass: true, feedback: .impact(weight: .light)) { perform(.radio) }
                    .accessibilityLabel("Start radio")
            }
            download
            if canSave, let model {
                let saved = header.saved == true
                IconButton(icon: saved ? .inLibrary : .saveToPlaylist, size: 48, iconSize: 22, active: saved, colour: theme.text, glass: true, feedback: .impact(weight: .medium)) {
                    app.toggleInLibrary(subscribe: false, in: model)
                }
                .accessibilityLabel(saved ? "Remove from library" : "Save to library")
            }
            if canSubscribe, let model {
                let subscribed = header.subscribed == true
                PillButton(title: subscribed ? "Subscribed" : "Subscribe", primary: !subscribed) {
                    app.toggleInLibrary(subscribe: true, in: model)
                }
            }
            if let link {
                Menu {
                    Button("Copy link") { app.copyLink(link) }
                    if let edit {
                        Button("Rename") { edit(.rename) }
                        Divider()
                        Picker("Who can see it", selection: privacy) {
                            ForEach(PlaylistPrivacy.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Delete playlist", role: .destructive) { edit(.delete) }
                    }
                } label: {
                    IconView(icon: .more, size: 22, colour: theme.text)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .accessibilityLabel("More")
            }
        }
    }

    /// Unknown shows as Private, as YouTube makes playlists.
    private var privacy: Binding<PlaylistPrivacy> {
        Binding(get: { header.privacy ?? .private }, set: { privacy in
            if let model { app.setPrivacy(privacy, in: model) }
        })
    }
}

private struct HeaderText: View {
    let header: PageHeader
    let foreground: Color
    let secondary: Color

    /// The title's size follows its length, then grows with the reader's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var titleScale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !header.label.isEmpty {
                Text(header.label)
                    .font(.subheadline.weight(.semibold))
            }
            Text(header.title)
                .font(.system(size: titleSize * titleScale, weight: .heavy))
                .tracking(-0.5)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            details
                .font(.subheadline)
                .lineLimit(2)
        }
        .foregroundStyle(foreground)
    }

    @ViewBuilder private var details: some View {
        let subtitle = Text(header.subtitle).fontWeight(.bold)
        let meta = Text(header.meta).foregroundStyle(secondary)
        switch (header.subtitle.isEmpty, header.meta.isEmpty) {
        case (false, false): Text("\(subtitle)  •  \(meta)")
        case (false, true): subtitle
        case (true, false): meta
        case (true, true): EmptyView()
        }
    }

    private var titleSize: CGFloat {
        switch header.title.count {
        case ...12: 44
        case ...18: 38
        case ...28: 32
        default: 28
        }
    }
}
