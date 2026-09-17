import SwiftUI

struct BureauView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var receipts: [DiveReceipt] = []
    @State private var error: String?
    @State private var loading = false
    @State private var hasMore = true
    let journal: ExpeditionJournal

    var body: some View {
        NavigationStack {
            List {
                Button("Готово") { dismiss() }.font(.body).frame(minHeight: 44)
                Section {
                    Text("Подводное бюро расследований").font(.title2.bold())
                    Text("Каждое погружение — отдельное дело. Чек расскажет, куда ушла батарейка и почему помят корпус.")
                }
                if let error { Section("Не удалось прочитать журнал") { Text(error); Button("Повторить") { Task { await load() } } } }
                if receipts.isEmpty && !loading && error == nil { Text("Дел пока нет. Начните экспедицию.") }
                ForEach(receipts) { receipt in
                    NavigationLink {
                        DiveCaseView(journal: journal, diveID: receipt.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(receipt.date, style: .date) + Text(" · ") + Text(receipt.date, style: .time)
                            Text(receipt.outcome)
                            Text("Дело №\(receipt.id.uuidString.prefix(8))").font(.body.monospaced())
                        }
                    }.accessibilityIdentifier("diveCase")
                }
                if loading { ProgressView("Открываем дела…") }
                if hasMore && !loading && error == nil { Button("Ещё дела") { Task { await load() } } }
            }
            .font(.body)
            .navigationTitle("Бюро расследований")
            .task { if receipts.isEmpty { await load() } }
        }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await journal.receipts(offset: receipts.count)
            receipts += page
            hasMore = page.count == 50
        } catch { self.error = error.localizedDescription }
    }
}

struct ReceiptPaper: View {
    let receipt: DiveReceipt
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ПОДВОДНОЕ БЮРО РАССЛЕДОВАНИЙ").font(.body)
            Text("ЧЕК · \(receipt.id.uuidString.prefix(8))")
            Text(receipt.date.formatted(date: .abbreviated, time: .standard))
            Divider()
            Text("Обнял риф — корпус помят: \(receipt.reefs)")
            Text("Форсаж — батарейку списали: \(receipt.boosts) × 7 энергии")
            Text(receipt.blackBoxes > 0 ? "Чёрный ящик — с собой" : "Чёрный ящик — не найден")
            Divider()
            Text(receipt.outcome).bold()
            Text("Спасибо за погружение. Тревожность возврату не подлежит.")
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.black)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.98, green: 0.95, blue: 0.85), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityIdentifier("diveReceipt")
    }
}

/// Used inline after every expedition, as well as inside the historical case.
struct LatestReceiptView: View {
    let journal: ExpeditionJournal
    let diveID: UUID
    @State private var receipt: DiveReceipt?
    @State private var error: String?
    var body: some View {
        VStack {
            if let receipt { ReceiptPaper(receipt: receipt) }
            else if let error {
                Text(error)
                Button("Повторить печать чека") { Task { await load() } }
            } else { ProgressView("Печатаем чек…") }
        }
        .task(id: diveID) { await load() }
    }
    @MainActor private func load() async {
        do {
            receipt = try await journal.receipts(diveID: diveID).first
            error = receipt == nil ? "Чек пока недоступен" : nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct DiveCaseView: View {
    let journal: ExpeditionJournal
    let diveID: UUID
    @State private var entries: [JournalEntry] = []
    @State private var error: String?
    @State private var loading = false
    @State private var hasMore = true
    var body: some View {
        List {
            LatestReceiptView(journal: journal, diveID: diveID)
            Section("Хронология · события и приборы") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "+%.1f с · %@", entry.elapsed, entry.severity)).font(.body.monospaced())
                        Text(entry.message).bold()
                        Text(entry.kind).font(.body.monospaced())
                        Text(String(format: "Энергия %.1f · корпус %d/3 · груз %d", entry.boat.energy, entry.boat.hull, entry.boat.cargo))
                        Text(String(format: "Координаты %.0f, %.0f · скорость %.1f", entry.boat.x, entry.boat.y, entry.boat.speed))
                        Text("\(entry.boat.zone) · \(entry.boat.state) · щит: \(entry.boat.shield ? "да" : "нет") · ящик: \(entry.boat.blackBox ? "да" : "нет")")
                    }.accessibilityElement(children: .combine)
                }
                if let error { Text(error); Button("Повторить") { Task { await load() } } }
                if loading { ProgressView("Читаем журнал…") }
                if hasMore && !loading && error == nil { Button("Ещё события") { Task { await load() } } }
            }
        }
        .font(.body)
            .navigationTitle("Дело №\(diveID.uuidString.prefix(8))")
        .task { if entries.isEmpty { await load() } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await journal.entries(diveID: diveID, offset: entries.count)
            entries += page
            hasMore = page.count == 200
        } catch { self.error = error.localizedDescription }
    }
}
