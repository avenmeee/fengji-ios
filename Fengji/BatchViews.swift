import SwiftUI
import PhotosUI

// 多张照片一次发的界面，设计稿在 视觉\批量发布。

/// 这些照片是……
struct BatchChoosePanel: View {
    @ObservedObject var batch: BatchModel
    /// 本月 AI 还够不够分这些照片
    let aiEnough: Bool
    let aiLeft: Int?
    let go: (BatchModel.Split) -> Void
    @State private var choice: BatchModel.Split

    init(batch: BatchModel, aiEnough: Bool, aiLeft: Int?, go: @escaping (BatchModel.Split) -> Void) {
        self.batch = batch
        self.aiEnough = aiEnough
        self.aiLeft = aiLeft
        self.go = go
        _choice = State(initialValue: aiEnough ? .ai : .eachOne)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("这些照片是……").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                Text("选了 \(batch.shots.count) 张").font(.system(size: 14)).foregroundStyle(Theme.sub)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(batch.shots) { s in
                        Image(uiImage: s.preview).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            VStack(spacing: 0) {
                row(.ai, icon: "sparkle", title: String(localized: "AI 帮我分"), note: aiEnough ? String(localized: "认出是几件，照片分好，名字价格填好") : String(localized: "这个月的 AI 不够分这些照片了"), rec: aiEnough, enabled: aiEnough)
                FormDivider()
                row(.eachOne, icon: "square.grid.2x2", title: String(localized: "每张一件"), note: String(localized: "一张照片发一件"))
                FormDivider()
                row(.allOne, icon: "photo", title: String(localized: "都是同一件"), note: String(localized: "同一件东西，拍了几个角度"))
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .padding(7)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
            if let aiLeft, aiLeft <= 10, aiEnough {
                Text("本月 AI 还剩 \(aiLeft) 条").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
            }
            Button("继续") { go(choice) }
                .buttonStyle(PrimaryButtonStyle(act: .ink))
        }
        .padding(.bottom, 4)
    }

    private func row(_ value: BatchModel.Split, icon: String, title: String, note: String, rec: Bool = false, enabled: Bool = true) -> some View {
        let on = choice == value
        return Button { choice = value } label: {
            HStack(spacing: 12) {
                ZStack {
                    Hexagon().fill(rec ? Theme.accent : Theme.fill).frame(width: 36, height: 36)
                    Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(rec ? Theme.onBuy : Theme.sub)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        if rec {
                            Text("推荐")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text(note).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                if on {
                    ZStack {
                        Hexagon().fill(Theme.accent).frame(width: 24, height: 24)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onBuy)
                    }
                } else {
                    Circle().stroke(Theme.line, lineWidth: 1.5).frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 正在认东西：一格一格亮起来
private struct BatchRecognizing: View {
    @ObservedObject var batch: BatchModel
    let cancel: () -> Void
    @State private var lit = Demo.isOn ? 3 : 0

    private var cells: [BatchModel.Shot] { Array(batch.shots.prefix(7)) }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let fit = HiveLayout.fit(cells.count, in: geo.size, maxRadius: 62)
                ZStack {
                    ForEach(Array(cells.enumerated()), id: \.element.id) { i, s in
                        Image(uiImage: s.preview).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: fit.radius * 2, height: fit.radius * 2)
                            .saturation(i <= lit ? 1 : 0)
                            .opacity(i <= lit ? 1 : 0.3)
                            .clipShape(Hexagon())
                            .overlay { if i == lit { Hexagon().stroke(Theme.accent, lineWidth: 4) } }
                            .scaleEffect(i == lit ? 1 : 0.96)
                            .position(fit.centers[i])
                            .zIndex(i == lit ? 1 : 0)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.easeOut(duration: 0.3), value: lit)
            }
            .frame(height: 340)
            .padding(.top, 60)
            Text("正在认东西…").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink)
            Text(String(localized: "\(batch.shots.count) 张照片，") + (batch.shots.count > 15 ? String(localized: "可能要半分钟") : String(localized: "一般十几秒")))
                .font(.system(size: 15)).foregroundStyle(Theme.sub)
            Spacer()
            Button("取消", action: cancel)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .task {
            guard !Demo.isOn else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if lit < cells.count - 1 { lit += 1 }
            }
        }
    }
}

/// 多张一次发：认的时候是蜂巢，认好了是确认页
struct BatchFlow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var batch: BatchModel
    let aiConsent: Bool
    let aiOn: Bool
    let backToChoose: () -> Void
    let exit: () -> Void
    let posted: ([Listing]) -> Void

    private enum Field: Hashable { case name(UUID), price(UUID), fee, place, time, contact }
    @FocusState private var focus: Field?
    @State private var tried = Demo.scene == "batch-missing"
    @State private var banner: String? = Demo.scene == "batch-missing" ? "还差 2 件没填好" : nil
    @State private var moving: UUID?
    @State private var addTo: UUID?
    @State private var showAdd = false
    @State private var addPicked: [PhotosPickerItem] = []
    @State private var askExit = false
    @State private var bannerTask: Task<Void, Never>?

    var body: some View {
        Group {
            if batch.grouping {
                BatchRecognizing(batch: batch) {
                    batch.cancel()
                    backToChoose()
                }
            } else {
                confirm
            }
        }
        .overlay {
            BottomPanel(shown: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
                if let moving { movePanel(moving) }
            }
        }
        .onAppear {
            if Demo.scene == "batch-move" { moving = batch.items.first?.shots.dropFirst().first }
        }
        .onChange(of: batch.aiLeft) { _, n in state.setAILeft(n) }
        .onChange(of: batch.grouping) { _, on in
            // AI 没认出来：光标停在第一件的名字上
            if !on, batch.notice != nil, let first = batch.items.first { focus = .name(first.id) }
        }
        .photosPicker(isPresented: $showAdd, selection: $addPicked, maxSelectionCount: max(1, BatchModel.maxPhotos - batch.shots.count), matching: .images)
        .onChange(of: addPicked) { _, picked in
            guard !picked.isEmpty, let addTo else { return }
            Task {
                var datas: [Data] = []
                for p in picked {
                    if let d = try? await p.loadTransferable(type: Data.self) { datas.append(d) }
                }
                await batch.attach(datas, to: addTo)
                addPicked = []
            }
        }
        .alert("不发了？", isPresented: $askExit) {
            Button("接着填", role: .cancel) {}
            Button("不发了", role: .destructive, action: exit)
        } message: {
            Text("这 \(batch.items.count) 件还没发，退出就没了。")
        }
    }

    // MARK: - 确认页

    private var confirm: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if let notice = batch.notice {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "sparkle").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.tint)
                            Text(notice).font(.system(size: 14)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(batch.items) { item in
                        card(item).id(item.id)
                    }
                    if !batch.items.isEmpty {
                        GroupHeader(title: String(localized: "这几件都一样的"), note: String(localized: "改一处 \(batch.items.count) 件一起改")).padding(.top, 14)
                        sharedCard
                    }
                    if let error = batch.error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Theme.warn).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
                .onTapGesture { focus = nil }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { publishBar(proxy) }
            .onChange(of: batch.badIndex) { _, i in
                guard let i, batch.items.indices.contains(i) else { return }
                withAnimation(.snappy) { proxy.scrollTo(batch.items[i].id, anchor: .center) }
            }
        }
        .overlay(alignment: .bottom) { blackBar.padding(.bottom, 84) }
        .animation(.easeOut(duration: 0.18), value: batch.items.map(\.id))
        .animation(.easeOut(duration: 0.18), value: banner)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(batch.aiGrouped ? "认出 \(batch.items.count) 件" : "\(batch.items.count) 件")
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("不发了") { askExit = true }
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.sub)
                    .frame(minHeight: 44)
            }
            Text(batch.notice != nil ? "点照片可以挪到别的件" : "名字、价格是 AI 填的，都能直接改。点照片可以挪到别的件")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func card(_ item: BatchModel.Item) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(item.shots, id: \.self) { photoTile($0) }
                    if batch.shots.count < BatchModel.maxPhotos {
                        Button {
                            addTo = item.id
                            showAdd = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(Theme.sub)
                                .frame(width: 68, height: 85)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1.5))
                                .padding(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("再加照片")
                    }
                }
            }
            .frame(width: 152)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(item.shots.count) 张照片").font(.system(size: 12.5)).foregroundStyle(Theme.hint).lineLimit(1)
                    Spacer()
                    Button {
                        focus = nil
                        showRemoved(item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.sub)
                            .frame(width: 26, height: 26)
                            .background(Theme.fill, in: Circle())
                            .frame(width: 44, height: 30, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删掉这件")
                }
                nameBox(item)
                priceBox(item)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        .padding(7)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func photoTile(_ id: UUID) -> some View {
        if let s = batch.shot(id) {
            Menu {
                Button { moving = id } label: { Label("移到别的件", systemImage: "arrow.right") }
                Button(role: .destructive) {
                    // 最后一张：这件也没了，黑条上能撤销
                    if let it = batch.items.first(where: { $0.shots.contains(id) }), it.shots.count == 1 {
                        showRemoved(it.id)
                    } else {
                        batch.removeShot(id)
                    }
                } label: { Label("删掉这张", systemImage: "trash") }
            } label: {
                Image(uiImage: s.preview).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 68, height: 85)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("照片")
        }
    }

    private func titleBinding(_ id: UUID) -> Binding<String> {
        Binding {
            batch.item(id)?.title ?? ""
        } set: { v in
            if let i = batch.items.firstIndex(where: { $0.id == id }) { batch.items[i].title = v }
        }
    }

    private func priceBinding(_ id: UUID) -> Binding<String> {
        Binding {
            batch.item(id)?.price ?? ""
        } set: { v in
            if let i = batch.items.firstIndex(where: { $0.id == id }) {
                batch.items[i].price = v
                batch.items[i].priceSuggested = false
            }
        }
    }

    @ViewBuilder
    private func nameBox(_ item: BatchModel.Item) -> some View {
        let lack = tried && BatchModel.noTitle(item)
        let loading = batch.describing.contains(item.id) && item.title.isEmpty
        HStack(spacing: 6) {
            TextField(loading ? "AI 正在认" : "名字", text: titleBinding(item.id))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .focused($focus, equals: .name(item.id))
            if loading { HoneyLoader(size: 18) }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lack ? Theme.warn : .clear, lineWidth: 1.5))
        if lack { Text("填一下名字").font(.system(size: 12.5)).foregroundStyle(Theme.warn) }
    }

    @ViewBuilder
    private func priceBox(_ item: BatchModel.Item) -> some View {
        let lack = tried && BatchModel.noPrice(item)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("$").font(.system(size: 16, weight: .semibold)).foregroundStyle(item.price.isEmpty ? Theme.hint : Theme.ink)
            TextField("价格", text: priceBinding(item.id))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .keyboardType(.numberPad)
                .lineLimit(1)
                .focused($focus, equals: .price(item.id))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lack ? Theme.warn : .clear, lineWidth: 1.5))
        if lack { Text("填一下价格").font(.system(size: 12.5)).foregroundStyle(Theme.warn) }
    }

    private var sharedCard: some View {
        FormCard {
            FieldBlock(label: String(localized: "取货方式")) {
                HStack(spacing: 8) {
                    Chip(text: String(localized: "自取"), on: batch.pickup, act: .buy) { batch.pickup.toggle() }
                    Chip(text: String(localized: "可配送"), on: batch.deliver, act: .buy) { batch.deliver.toggle() }
                }
            }
            if batch.deliver {
                FormDivider()
                FieldBlock(label: String(localized: "配送费")) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("$").font(.system(size: 17)).foregroundStyle(batch.deliveryFee.isEmpty ? Theme.hint : Theme.ink)
                        line(String(localized: "0，不收就空着"), $batch.deliveryFee, .fee).keyboardType(.numberPad)
                    }
                }
            }
            if batch.pickup {
                FormDivider()
                FieldBlock(label: String(localized: "自取地点")) { line(String(localized: "比如 Monty 楼下"), $batch.place, .place) }
            }
            FormDivider()
            FieldBlock(label: String(localized: "方便的时间")) { line(String(localized: "比如 工作日晚上、周末"), $batch.availTime, .time) }
            FormDivider()
            FieldBlock(label: String(localized: "微信号"), hint: String(localized: "填了别人能看到")) {
                line(String(localized: "微信号"), $batch.contact, .contact)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .environment(\.formLarge, true)
    }

    private func line(_ placeholder: String, _ text: Binding<String>, _ field: Field) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 17))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .focused($focus, equals: field)
            .frame(minHeight: 30)
    }

    private func publishBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Button {
                publish(proxy)
            } label: {
                HStack(spacing: 8) {
                    if batch.publishing { HoneyLoader(size: 22) }
                    Text(batch.publishing ? "正在发" : "发布 \(batch.items.count) 件").lineLimit(1)
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink, dimmed: !batch.missing.isEmpty))
            .disabled(batch.publishing || batch.items.isEmpty)
            if focus != nil {
                Button("完成") { focus = nil }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 72, height: 54)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 17))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.bg)
    }

    private func publish(_ proxy: ScrollViewProxy) {
        focus = nil
        batch.clearRemoved()
        tried = true
        let lack = batch.missing
        if let first = lack.first {
            show(String(localized: "还差 \(lack.count) 件没填好"))
            withAnimation(.snappy) { proxy.scrollTo(batch.items[first].id, anchor: .center) }
            return
        }
        Task {
            if let saved = await batch.publish(aiConsent: aiConsent) { posted(saved) }
        }
    }

    // MARK: - 底部黑条

    @ViewBuilder
    private var blackBar: some View {
        if let r = batch.removed {
            HStack(spacing: 14) {
                Text(r.item.title.isEmpty ? "删掉了一件" : "删掉了“\(r.item.title)”").lineLimit(1)
                Button("撤销") {
                    batch.undoRemove()
                    bannerTask?.cancel()
                }
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accent)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
            .transition(.opacity)
        } else if let banner {
            Text(banner)
                .font(.subheadline)
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func showRemoved(_ id: UUID) {
        batch.removeItem(id)
        autoClear { batch.clearRemoved() }
    }

    private func show(_ text: String) {
        banner = text
        autoClear { banner = nil }
    }

    private func autoClear(_ clear: @escaping () -> Void) {
        guard !Demo.isOn else { return }
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { clear() }
        }
    }

    // MARK: - 移到别的件

    private func movePanel(_ shot: UUID) -> some View {
        let current = batch.items.first { $0.shots.contains(shot) }
        let canSplit = (current?.shots.count ?? 0) > 1
        let height = CGFloat(batch.items.count + (canSplit ? 1 : 0)) * 66
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("移到哪一件").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                Text("这张照片会挪过去").font(.system(size: 14)).foregroundStyle(Theme.sub)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(batch.items.enumerated()), id: \.element.id) { i, it in
                        if i > 0 { FormDivider() }
                        moveRow(it, shot: shot, current: it.id == current?.id)
                    }
                    if canSplit {
                        FormDivider()
                        Button {
                            batch.splitOut(shot, consent: aiConsent, aiOn: aiOn)
                            moving = nil
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Hexagon().fill(Theme.accentSoft).frame(width: 36, height: 36)
                                    Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.tint)
                                }
                                .frame(width: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("单独成一件").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.ink)
                                    Text(aiOn ? "AI 再认一下名字和价格" : "名字和价格自己填").font(.system(size: 13)).foregroundStyle(Theme.hint)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 66)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: min(height, 420))
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .padding(7)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveRow(_ it: BatchModel.Item, shot: UUID, current: Bool) -> some View {
        return Button {
            batch.move(shot, to: it.id)
            moving = nil
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let first = it.shots.first.flatMap({ batch.shot($0) }) {
                        Image(uiImage: first.preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.fill
                    }
                }
                .frame(width: 40, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.title.isEmpty ? String(localized: "还没名字") : it.title).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(current ? "现在在这一件" : "\(it.shots.count) 张照片").font(.system(size: 13)).foregroundStyle(Theme.hint)
                }
                Spacer(minLength: 4)
                if !current {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.hint)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 66)
            .opacity(current ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
    }
}
