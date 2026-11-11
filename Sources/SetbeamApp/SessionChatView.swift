import AppKit
import SwiftUI
import SetbeamCore

/// Conversation stays beside the single main picture. Images open only on request.
struct SessionChatView: View {
    @ObservedObject var model: SessionModel
    @FocusState private var composing: Bool
    @State private var editingIdentity = false
    @State private var showingDetails = false
    @State private var focusedMessage: Int?
    @State private var actionMessage: Int?
    @State private var pendingChatScroll = false
    @FocusState private var conversationFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.state.sharing {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if model.chatMessages.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Start the conversation").font(.headline)
                                    Text("Send a note or attach a frame for everyone in this session.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ForEach(Array(model.chatMessages.enumerated()), id: \.element.id) { index, message in
                                ChatBubbleRow(model: model, message: message, startsGroup: startsGroup(at: index),
                                    keyboardFocused: conversationFocused && focusedMessage == message.id,
                                    showingActions: Binding(get: { actionMessage == message.id }, set: { shown in if shown { actionMessage = message.id; focusedMessage = message.id } else if actionMessage == message.id { actionMessage = nil } })) {
                                    model.chatReplyTo = message.id; composing = true
                                }.id(message.id)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .focusable().focusEffectDisabled().focused($conversationFocused)
                    .onKeyPress(.upArrow) { moveMessage(-1); return .handled }
                    .onKeyPress(.downArrow) { moveMessage(1); return .handled }
                    .onKeyPress(.return) { actionMessage = focusedMessage ?? model.chatMessages.last?.id; return .handled }
                    .onChange(of: conversationFocused) { _, focused in if focused && focusedMessage == nil { focusedMessage = model.chatMessages.last?.id } }
                    .onChange(of: focusedMessage) { _, id in if conversationFocused && actionMessage == nil, let id { scroll.scrollTo(id, anchor: .bottom) } }
                    .onAppear { if let id = model.chatMessages.last?.id { scroll.scrollTo(id, anchor: .bottom) } }
                    .onChange(of: model.chatMessages.last?.id) { _, id in
                        if actionMessage != nil { pendingChatScroll = true }
                        else if let id { scroll.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: actionMessage) { _, id in
                        if id == nil && pendingChatScroll { pendingChatScroll = false; if let last = model.chatMessages.last?.id { scroll.scrollTo(last, anchor: .bottom) } }
                    }
                }
                composer.padding(16)
            } else {
                ContentUnavailableView("Sharing is off", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start sharing to open a session chat. Chat clears when sharing stops."))
            }
        }.font(.body).onAppear { model.markChatRead() }
            .onChange(of: model.chatMessages) { _, messages in
                if let id = actionMessage, !messages.contains(where: { $0.id == id }) { actionMessage = nil }
                if let id = focusedMessage, !messages.contains(where: { $0.id == id }) { focusedMessage = nil }
            }
    }

    private func moveMessage(_ direction: Int) {
        guard !model.chatMessages.isEmpty else { return }
        let index = focusedMessage.flatMap { id in model.chatMessages.firstIndex(where: { $0.id == id }) } ?? (direction < 0 ? model.chatMessages.count : -1)
        focusedMessage = model.chatMessages[max(0, min(model.chatMessages.count - 1, index + direction))].id
    }

    private func startsGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = model.chatMessages[index - 1], message = model.chatMessages[index]
        return previous.authorNumber != message.authorNumber || previous.name != message.name ||
            previous.color != message.color || message.sentAt - previous.sentAt > 300
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                if let parent = model.chatReplyTo {
                    draftDetail("Replying to \(model.chatMessages.first { $0.id == parent }?.name ?? "message")",
                                symbol: "arrowshape.turn.up.left", cancelLabel: "Cancel Reply") { model.chatReplyTo = nil }
                }
                if let data = model.chatAttachment, let image = NSImage(data: data) {
                    HStack(spacing: 8) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 32)
                        Text("Frame attached").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        cancelButton("Remove Frame") { model.clearChatAttachment() }
                    }
                }
                TextField("Message everyone…", text: $model.chatText, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).focused($composing)
                    .accessibilityLabel("Message everyone").onSubmit { model.sendChat() }
                HStack(spacing: 8) {
                    Button { model.captureChatFrame() } label: {
                        Image(systemName: "camera").frame(width: 28, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(!model.canCaptureChatFrame || model.chatCapturing)
                        .help(captureHelp)
                        .accessibilityLabel(model.canCaptureChatFrame && !model.chatCapturing ? "Capture Frame" : "Capture Frame. \(captureHelp)")
                    Button { editingIdentity.toggle() } label: {
                        HStack(spacing: 4) {
                            arrow(model.chatOperatorColor.rawValue).frame(width: 12, height: 16)
                            Text(model.chatOperatorName.isEmpty ? "DigiTech" : model.chatOperatorName).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption)
                        }.font(.caption).frame(maxWidth: 112, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("Edit your chat name and color")
                        .accessibilityLabel("Edit your chat identity")
                        .popover(isPresented: $editingIdentity) { identityEditor }
                    Spacer(minLength: 0)
                    Button("Send") { model.sendChat() }.buttonStyle(.borderedProminent).controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command).help("Send message (⌘Return)")
                        .disabled(model.chatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.chatAttachment == nil)
                }
            }.padding(12)
                // One quiet border groups the draft and its controls without a second toolbar.
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(composing ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1) }
            if let error = model.chatProblem { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 4) {
                Text("Not encrypted · Clears at Stop").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { showingDetails.toggle() } label: {
                    Image(systemName: "info.circle").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("About session chat").accessibilityLabel("About session chat")
                    .popover(isPresented: $showingDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Session chat").font(.headline)
                            Text("Messages and images are shared with admitted viewers on this network. Chat is not encrypted and clears when sharing stops. Images already sent remain in chat during Hold.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }.padding(20).frame(width: 280)
                    }
            }
        }
    }

    private var captureHelp: String {
        if model.chatCapturing { return "Preparing the attached frame…" }
        if model.audienceControl.pending != nil || model.busy { return "Wait for the sharing change to finish before capturing a frame" }
        if model.state.holding { return "Resume sharing before capturing a frame" }
        if !model.canCaptureChatFrame { return "Wait for the outgoing picture to be confirmed before capturing a frame" }
        return "Attach a frame from the shared feed"
    }

    private var identityEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your chat identity").font(.headline)
            TextField("Your name", text: $model.chatOperatorName).textFieldStyle(.roundedBorder)
            Picker("Color", selection: $model.chatOperatorColor) {
                ForEach(PointerColor.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            HStack { Spacer(); Button("Done") { editingIdentity = false } }
        }.padding(20).frame(width: 280)
    }

    private func draftDetail(_ title: String, symbol: String, cancelLabel: String, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(title)
            Spacer(minLength: 0)
            cancelButton(cancelLabel, action: cancel)
        }
    }
    private func cancelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }
    private func arrow(_ rawColor: String) -> some View {
        let color = PointerColor(rawValue: rawColor) ?? .blue
        return PointerArrow().fill(Color(red: color.rgb.red, green: color.rgb.green, blue: color.rgb.blue))
            .frame(width: 12, height: 16).accessibilityHidden(true)
    }
}

private struct ChatImageAttachment: View {
    let image: NSImage
    let title: String
    let sample: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image")
                    if sample { Text("Sample media").foregroundStyle(.secondary) }
                }.font(.caption)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).focusable(false).help("Open \(title)")
    }
}

private struct ChatBubbleRow: View {
    @ObservedObject var model: SessionModel
    let message: ChatMessage
    let startsGroup: Bool
    let keyboardFocused: Bool
    @Binding var showingActions: Bool
    let reply: () -> Void
    @State private var hovering = false
    @State private var imageExpanded = false
    @State private var suppressImageClickUntil = Date.distantPast
    @State private var hoveredAction: PaletteAction?
    @FocusState private var paletteFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    private var own: Bool { message.ownMessage }
    private var selected: ChatReaction? { message.reactions.first(where: \.selected)?.reaction }
    private var alignment: HorizontalAlignment { own ? .trailing : .leading }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if own { Spacer(minLength: 24); moreButton }
            VStack(alignment: alignment, spacing: 4) {
                if startsGroup && !own {
                    HStack(spacing: 4) {
                        let color = PointerColor(rawValue: message.color) ?? .blue
                        PointerArrow().fill(Color(red: color.rgb.red, green: color.rgb.green, blue: color.rgb.blue))
                            .frame(width: 12, height: 16).accessibilityHidden(true)
                        Text(verbatim: message.name).lineLimit(1).help(message.name)
                        if message.operatorMessage { Image(systemName: "checkmark.seal.fill").help("DigiTech") }
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                bubble
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(message.reactions.prefix(3)), id: \.reaction) { summary in
                            Button { showingActions = true } label: {
                                Text("\(summary.reaction.emoji) \(summary.count)").font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(summary.selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                            }.buttonStyle(.plain).focusable(false).help("Change your reaction")
                        }
                        if message.reactions.count > 3 {
                            Button { showingActions = true } label: {
                                Text("+\(message.reactions.count - 3)").font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(message.reactions.dropFirst(3).contains(where: \.selected) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                            }.buttonStyle(.plain).focusable(false).help("Show all reactions")
                        }
                    }
                }
            }.frame(maxWidth: 240, alignment: own ? .trailing : .leading)
            if !own { moreButton; Spacer(minLength: 24) }
        }.padding(.top, startsGroup ? 12 : 0)
            .onHover { hovering = $0 }
            .contextMenu { contextActions }
            .popover(isPresented: Binding(get: { showingActions || imageExpanded }, set: { shown in
                if !shown { showingActions = false; imageExpanded = false }
            })) {
                if imageExpanded { enlargedImage } else { actionPalette }
            }
            .onChange(of: message.hasFrame) { _, hasFrame in if !hasFrame { if imageExpanded { imageExpanded = false; showingActions = false }; hoveredAction = nil } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibleMessage)
            .accessibilityActions {
                Button("Reply", action: reply)
                ForEach(ChatReaction.allCases, id: \.self) { reaction in
                    Button("\(selected == reaction ? "Remove" : "React with") \(reaction.label)") { model.reactChat(message, reaction: reaction) }
                }
                if !message.text.isEmpty { Button("Copy") { copyText() } }
                if message.hasFrame { Button("Open Image") { imageExpanded = true; showingActions = true } }
                Button("Remove for Everyone") { model.removeChat(message) }
            }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parent = message.replyTo {
                let original = model.chatMessages.first { $0.id == parent }
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 2)
                    Text(verbatim: original.map { "\($0.name): \($0.text.isEmpty ? "Image" : $0.text)" } ?? "Original message unavailable")
                        .font(.caption).lineLimit(2).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if !message.text.isEmpty { Text(verbatim: message.text).fixedSize(horizontal: false, vertical: true) }
            else if !message.hasFrame { Text("Image no longer available").font(.caption).foregroundStyle(.secondary) }
            if message.hasFrame, let image = model.chatImages[message.id] {
                ChatImageAttachment(image: image, title: "Image from \(message.name)", sample: message.sampleFrame) {
                    let allowed = Date() >= suppressImageClickUntil; suppressImageClickUntil = .distantPast
                    if allowed { imageExpanded = true; showingActions = true }
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .background(own ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                if keyboardFocused { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2) }
                else if contrast == .increased { RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary, lineWidth: 1) }
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                suppressImageClickUntil = Date().addingTimeInterval(0.8); showingActions = true
            })
            .help("Sent \(Date(timeIntervalSince1970: message.sentAt).formatted(date: .omitted, time: .shortened)). Right-click for message actions.")
    }

    private var moreButton: some View {
        Button { showingActions = true } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).focusable(false).foregroundStyle(.secondary)
            .opacity(hovering || keyboardFocused || showingActions ? 1 : 0)
            .help("Reply or react to this message").accessibilityLabel("Message actions")
    }

    @ViewBuilder private var contextActions: some View {
        Picker("Reaction", selection: Binding<ChatReaction?>(get: { selected }, set: { value in
            if let value { model.reactChat(message, reaction: value) }
            else if let selected { model.reactChat(message, reaction: selected) }
        })) {
            Label("None", systemImage: "xmark").tag(Optional<ChatReaction>.none)
            ForEach(ChatReaction.allCases, id: \.self) { reaction in
                Label { Text(reaction.label) } icon: { Image(nsImage: ChatPaletteImages.image(reaction)).renderingMode(.original) }.tag(Optional(reaction)).accessibilityLabel("\(reaction.label)\(selected == reaction ? ", selected" : "")")
            }
        }.pickerStyle(.palette)
        Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
        if !message.text.isEmpty { Button("Copy", systemImage: "doc.on.doc") { copyText() } }
        if message.hasFrame { Button("Open Image", systemImage: "photo") { imageExpanded = true; showingActions = true } }
        Divider()
        Button("Remove for Everyone", systemImage: "trash", role: .destructive) { model.removeChat(message) }
    }

    private enum PaletteAction: Equatable { case reaction(ChatReaction), reply, copy, image, remove }
    private func highlighted(_ action: PaletteAction) -> Bool { hoveredAction == action }
    private func perform(_ action: PaletteAction) {
        switch action {
        case .reaction(let reaction): model.reactChat(message, reaction: reaction); showingActions = false
        case .reply: showingActions = false; DispatchQueue.main.async { reply() }
        case .copy: copyText(); showingActions = false
        case .image: imageExpanded = true; showingActions = true
        case .remove: model.removeChat(message); showingActions = false
        }
    }
    private func paletteKey(_ key: KeyPress) -> KeyPress.Result {
        let character = key.characters.lowercased()
        if key.modifiers.isEmpty, let digit = Int(character), (1...6).contains(digit) { perform(.reaction(ChatReaction.allCases[digit - 1])) }
        else if character == "r" && key.modifiers.isEmpty { perform(.reply) }
        else if character == "i" && key.modifiers.isEmpty && message.hasFrame { perform(.image) }
        else if character == "c" && key.modifiers.contains(.command) && !message.text.isEmpty { perform(.copy) }
        else if character == "d" && key.modifiers == .shift { perform(.remove) }
        else { return .ignored }
        return .handled
    }
    private func paletteRow(_ title: String, symbol: String, action: PaletteAction) -> some View {
        Button(role: action == .remove ? .destructive : nil) { perform(action) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                .background(highlighted(action) ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.onHover { hover in hoveredAction = hover ? action : nil }
    }
    private var actionPalette: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sent \(Date(timeIntervalSince1970: message.sentAt).formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(ChatReaction.allCases, id: \.self) { reaction in
                    Button { perform(.reaction(reaction)) } label: {
                        Text(reaction.emoji).font(.system(size: 20)).frame(width: 28, height: 28)
                            .background(selected == reaction ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay { if highlighted(.reaction(reaction)) { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) } }
                    }.help(reaction.label)
                        .accessibilityLabel("\(selected == reaction ? "Remove" : "React with") \(reaction.label)")
                        .onHover { hover in hoveredAction = hover ? .reaction(reaction) : nil }
                }
            }
            if !message.reactions.isEmpty {
                Text(message.reactions.map { "\($0.reaction.emoji) \($0.count)" }.joined(separator: "  "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            paletteRow("Reply", symbol: "arrowshape.turn.up.left", action: .reply)
            if !message.text.isEmpty { paletteRow("Copy", symbol: "doc.on.doc", action: .copy) }
            if message.hasFrame { paletteRow("Open Image", symbol: "photo", action: .image) }
            paletteRow("Remove for Everyone", symbol: "trash", action: .remove)
        }.buttonStyle(.plain).padding(16)
            .focusable().focusEffectDisabled().focused($paletteFocused)
            .onAppear { hoveredAction = nil; paletteFocused = true }
            .onKeyPress(phases: .down, action: paletteKey)
            .accessibilityElement(children: .contain).accessibilityLabel("Message actions")
            .accessibilityHint("Keys 1 through 6 react; R replies; Command-C copies; I opens the image; Shift-D removes for everyone.")
    }
    @ViewBuilder private var enlargedImage: some View {
        if let image = model.chatImages[message.id] {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Image from \(message.name)").font(.headline); Spacer(); Button("Done") { imageExpanded = false; showingActions = false } }
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 320)
                if message.sampleFrame { Text("Sample media").font(.caption).foregroundStyle(.secondary) }
            }.padding(20).frame(width: 400)
        }
    }
    private func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
    private var accessibleMessage: String {
        var parts = [message.name + (message.operatorMessage ? ", operator" : ""),
                     Date(timeIntervalSince1970: message.sentAt).formatted(date: .omitted, time: .shortened)]
        if let original = message.replyTo.flatMap({ id in model.chatMessages.first(where: { $0.id == id }) }) {
            parts.append("Reply to \(original.name): \(original.text.isEmpty ? "Image" : original.text)")
        }
        if !message.text.isEmpty { parts.append(message.text) }
        else if !message.hasFrame { parts.append("Image no longer available") }
        if message.hasFrame { parts.append(message.sampleFrame ? "Image attached. Sample media" : "Image attached") }
        parts += message.reactions.map { "\($0.reaction.label), \($0.count)\($0.selected ? ", selected" : "")" }
        return parts.joined(separator: ". ")
    }
}


@MainActor private enum ChatPaletteImages {
    private static let icons: [ChatReaction: NSImage] = Dictionary(uniqueKeysWithValues: ChatReaction.allCases.map { reaction in
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: 40, height: 40))
        (reaction.emoji as NSString).draw(in: NSRect(x: 2, y: 2, width: 36, height: 36), withAttributes: [.font: NSFont.systemFont(ofSize: 30)])
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 20, height: 20)); image.addRepresentation(bitmap); image.isTemplate = false
        return (reaction, image)
    })
    static func image(_ reaction: ChatReaction) -> NSImage { icons[reaction]! }
}
