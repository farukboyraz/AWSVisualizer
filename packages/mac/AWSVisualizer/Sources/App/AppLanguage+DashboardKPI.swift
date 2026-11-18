import Foundation

/// Text of the KPI cards' detail windows, section sizes and loaders.
extension AppLanguage {
    private func k(_ en: String, _ tr: String) -> String { self == .tr ? tr : en }

    // MARK: Sizes

    func widgetSizeLabel(_ size: DashboardPrefs.WidgetSize) -> String {
        switch size {
        case .small: k("Small", "Küçük")
        case .medium: k("Medium", "Orta")
        case .large: k("Large", "Büyük")
        }
    }

    func widgetSizeShort(_ size: DashboardPrefs.WidgetSize) -> String {
        switch size {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    func widgetSizeWidth(_ size: DashboardPrefs.WidgetSize) -> String {
        switch size {
        case .small: k("¼ row", "¼ satır")
        case .medium: k("½ row", "½ satır")
        case .large: k("full row", "tam satır")
        }
    }

    var dashArrangeShow: String { k("Show on the dashboard", "Dashboard'da göster") }
    var dashArrangeHide: String { k("Hide from the dashboard", "Dashboard'dan gizle") }
    var dashArrangeSize: String { k("Size", "Boyut") }

    // MARK: KPI cards

    var dashKpiOpenHint: String { k("Click for details", "Ayrıntılar için tıklayın") }
    func dashActiveOfCategory(active: Int, total: Int) -> String { "\(active) / \(total)" }
    var dashNothingActive: String { k("No service has resources yet", "Henüz kaynağı olan servis yok") }
    var dashAttentionUnreadable: String { k("Couldn't read", "Okunamadı") }
    var dashAttentionInstall: String { k("Packages missing", "Paket eksik") }

    // MARK: Detail windows

    var dashSearchServices: String { k("Search services", "Servis ara") }
    var dashNoMatch: String { k("Nothing matches the search", "Aramaya uyan yok") }
    var dashResourcesDetailSubtitle: String { k("Every service, most resources first", "Tüm servisler, kaynağı en çok olandan aza") }
    var dashActiveDetailSubtitle: String { k("Services that have resources, most first", "Kaynağı olan servisler, en çoktan aza") }
    var dashCostDetailAll: String { k("All", "Tümü") }
    var dashCostDetailByMonth: String { k("Month based", "Ay bazlı") }
    var dashCostDetailAllHint: String { k("Services over the whole period, most expensive first", "Tüm dönem boyunca servisler, en çok tutandan aza") }
    var dashCostDetailMonthHint: String { k("Newest month first; services most expensive first", "En yeni ay başta; servisler en çok tutandan aza") }
    var dashAttentionDetailSubtitle: String { k("Services the dashboard couldn't count", "Dashboard'un sayamadığı servisler") }
    var dashAttentionUnreadableHint: String {
        k("The count request failed - usually no permission for this service with this profile, or the service isn't available in this region. Open the service to see the exact error.",
          "Sayım isteği başarısız oldu - genellikle bu profilin servise yetkisi yok ya da servis bu bölgede yok. Hatanın tamamını görmek için servisi açın.")
    }
    var dashAttentionInstallHint: String {
        k("Its SDK packages aren't installed, so it can't be counted yet.",
          "SDK paketleri yüklü olmadığı için henüz sayılamıyor.")
    }
    func dashServiceCount(_ n: Int) -> String { n == 1 ? k("1 service", "1 servis") : k("\(n) services", "\(n) servis") }
    var dashExpandAll: String { k("Expand all", "Tümünü aç") }
    var dashCollapseAll: String { k("Collapse all", "Tümünü kapat") }
    var dashInstallAll: String { k("Install all", "Hepsini yükle") }
    var dashInstall: String { k("Install", "Yükle") }

    // MARK: Spend chart

    var dsSingleColor: String { k("Spend chart in one color (default)", "Harcama grafiği tek renk (varsayılan)") }
    var dashSingleColor: String { k("One color", "Tek renk") }
    var dashMultiColor: String { k("Colors", "Renkli") }
    func dashDayCount(_ n: Int) -> String { n == 1 ? k("1 day", "1 gün") : k("\(n) days", "\(n) gün") }
    var dashServiceSpendSubtitle: String { k("This service's spend, newest first", "Bu servisin harcaması, en yeniden eskiye") }
    var dashSpendSettings: String { k("Spend settings", "Harcama ayarları") }
    var dashSpendView: String { k("View", "Görünüm") }
    var dashSpendPeriod: String { k("Period", "Dönem") }
    var dashSpendChartType: String { k("Chart type", "Grafik türü") }
    var dashSpendColors: String { k("Colors", "Renk") }
    var dashCostPeriodSubtitle: String { k("Services of this period, most expensive first", "Bu dönemin servisleri, en çok tutandan aza") }
    var dashChartClickHint: String { k("Click for details", "Ayrıntılar için tıklayın") }

    // MARK: Loading

    var dashLoadingSection: String { k("Loading…", "Yükleniyor…") }
}
