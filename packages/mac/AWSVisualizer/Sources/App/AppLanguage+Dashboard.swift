import Foundation

/// Dashboard text. AWS category and service names stay as AWS writes them.
extension AppLanguage {
    private func t(_ en: String, _ tr: String) -> String { self == .tr ? tr : en }

    var dashTitle: String { t("Dashboard", "Genel Bakış") }
    var dashSubtitle: String { t("Your selected AWS services at a glance", "Seçtiğin AWS servislerinin özeti") }
    func dashUpdated(_ time: String) -> String { t("Updated \(time)", "Güncellendi \(time)") }
    var dashRefresh: String { t("Refresh", "Yenile") }
    var dashEmpty: String { t("Select some services in Settings to see them here", "Burada görmek için Ayarlar'dan servis seç") }

    var dashResources: String { t("Resources", "Kaynak") }
    func dashResourcesHint(_ services: Int) -> String { t("across \(services) services", "\(services) serviste") }
    var dashActive: String { t("Active services", "Aktif servis") }
    func dashActiveHint(_ total: Int) -> String { t("of \(total) have resources", "/ \(total) serviste kaynak var") }
    var dashMonthToDate: String { t("Month to date", "Bu ay") }
    func dashEstimate(_ value: String) -> String { t("≈ \(value) by month end", "Ay sonu tahmini ≈ \(value)") }
    var dashCostHidden: String { t("No Cost Explorer access", "Cost Explorer yetkisi yok") }
    var dashCostHiddenHint: String { t("This role can't read billing data", "Bu rol fatura verisini okuyamıyor") }
    var dashCostUnavailable: String { t("Cost unavailable", "Maliyet alınamadı") }
    var dashAttention: String { t("Needs attention", "Dikkat gerektiren") }
    var dashAttentionNone: String { t("All services reachable", "Tüm servislere erişiliyor") }
    func dashAttentionHint(unreadable: Int, install: Int) -> String {
        var parts: [String] = []
        if unreadable > 0 { parts.append(t("\(unreadable) unreadable", "\(unreadable) okunamadı")) }
        if install > 0 { parts.append(t("\(install) need packages", "\(install) paket bekliyor")) }
        return parts.isEmpty ? t("no problems found", "sorun yok") : parts.joined(separator: " · ")
    }

    var dashDistribution: String { t("Resources by category", "Kategoriye göre kaynaklar") }
    var dashTopServices: String { t("Largest services", "En çok kaynağı olan servisler") }
    var dashNoResources: String { t("No resources found in this region yet", "Bu bölgede henüz kaynak bulunamadı") }
    var dashSpendTrend: String { t("Daily spend", "Günlük harcama") }
    var dashSpendByService: String { t("Spend by service", "Servise göre harcama") }
    var dashNoSpend: String { t("No spend recorded in this period", "Bu dönemde harcama yok") }
    func dashDailyAverage(_ value: String) -> String { t("avg \(value) / day", "günlük ort. \(value)") }
    var dashOther: String { t("Other", "Diğer") }
    var dashServices: String { t("Services", "Servisler") }
    func dashCategorySummary(services: Int, resources: Int) -> String {
        t("\(services) services · \(resources) resources", "\(services) servis · \(resources) kaynak")
    }
    var dashUnreadable: String { t("Couldn't read the count (missing permission or not available in this region)", "Sayı okunamadı (yetki yok ya da bu bölgede yok)") }
    var dashNeedsInstall: String { t("Packages not installed - open to install", "Paketler kurulu değil - kurmak için aç") }
    var dashOpen: String { t("Open", "Aç") }

    // MARK: Settings › Display › Dashboard

    var dsSections: String { t("Sections", "Bölümler") }
    var dsSectionsNote: String { t("A hidden section's data is never requested. With every cost section off the app makes no Cost Explorer call (billed per request); with every resource section off it lists nothing on AWS.", "Kapalı bir bölümün verisi hiç istenmez. Bütün maliyet bölümleri kapalıysa Cost Explorer'a (istek başına ücretli) hiç istek gitmez; bütün kaynak bölümleri kapalıysa AWS'de hiçbir şey listelenmez.") }
    func dsWidget(_ widget: DashboardPrefs.Widget) -> String {
        switch widget {
        case .resourcesKpi: return t("Resources card", "Kaynak kartı")
        case .activeKpi: return t("Active services card", "Aktif servis kartı")
        case .costKpi: return t("Spend card", "Harcama kartı")
        case .attentionKpi: return t("Needs attention card", "Dikkat gerektiren kartı")
        case .customCards: return t("My cards", "Kartlarım")
        case .distribution: return t("Resources by category", "Kategoriye göre kaynaklar")
        case .topServices: return t("Largest services", "En çok kaynağı olan servisler")
        case .costTrend: return t("Spend trend", "Harcama grafiği")
        case .costByService: return t("Spend by service", "Servise göre harcama")
        case .services: return t("Services list", "Servis listesi")
        }
    }
    var dsUsesCounts: String { t("resource counts", "kaynak sayıları") }
    var dsUsesCost: String { t("Cost Explorer", "Cost Explorer") }
    var dsUsesCards: String { t("each card's own request", "her kartın kendi isteği") }

    var dsCost: String { t("Cost", "Maliyet") }
    var dsCostView: String { t("Default view", "Varsayılan görünüm") }
    var dsCostViewNote: String { t("Daily: the last 30 days day by day. Monthly: the last months side by side. One month: a month you pick, day by day. You can also switch on the dashboard; each new view is one Cost Explorer request, repeated views are served from a 30-minute cache.", "Günlük: son 30 gün, gün gün. Aylık: son aylar yan yana. Tek ay: seçtiğin bir ay, gün gün. Dashboard üzerinde de değiştirebilirsin; her yeni görünüm bir Cost Explorer isteğidir, aynı görünüm 30 dakika önbellekten gelir.") }
    func costViewLabel(_ view: DashboardPrefs.CostView) -> String {
        switch view {
        case .daily: return t("Daily", "Günlük")
        case .monthly: return t("Monthly", "Aylık")
        case .month: return t("One month", "Tek ay")
        }
    }
    var dsMonths: String { t("Monthly range", "Aylık aralık") }
    func monthsLabel(_ n: Int) -> String { t("\(n) months", "\(n) ay") }
    var dsShowEstimate: String { t("Month-end estimate", "Ay sonu tahmini") }
    var dsCostOff: String { t("Every cost section is off - no Cost Explorer requests.", "Bütün maliyet bölümleri kapalı - Cost Explorer'a istek gitmiyor.") }

    var dsLook: String { t("Appearance", "Görünüm") }
    var dsColors: String { t("Colors", "Renkler") }
    func colorStyleLabel(_ style: DashboardPrefs.ColorStyle) -> String { style == .muted ? t("Muted", "Sönük") : t("Vivid", "Canlı") }
    var dsHideEmpty: String { t("Hide services with no resources", "Kaynağı olmayan servisleri gizle") }
    var dsAutoRefresh: String { t("Auto refresh", "Otomatik yenileme") }
    func refreshLabel(_ minutes: Int) -> String { minutes == 0 ? t("Off", "Kapalı") : t("\(minutes) min", "\(minutes) dk") }
    var dsAutoRefreshNote: String { t("Re-reads the resource counts (one list call per shown service). Cost comes from the 30-minute cache.", "Kaynak sayılarını yeniden okur (gösterilen her servis için bir listeleme isteği). Maliyet 30 dakikalık önbellekten gelir.") }

    var dsServices: String { t("Services on the dashboard", "Dashboard'daki servisler") }
    var dsServicesNote: String { t("Turned-off services are left out and never counted - no AWS request is made for them.", "Kapatılan servisler dashboard'a girmez ve sayılmaz - onlar için AWS'ye istek gitmez.") }
    var dsNoServices: String { t("No services selected yet (Settings › Services).", "Henüz servis seçilmedi (Ayarlar › Servisler).") }
    func dsServicesCount(shown: Int, total: Int) -> String { t("\(shown) of \(total) shown", "\(total) servisten \(shown) gösteriliyor") }
    var dsAll: String { t("All", "Tümü") }
    var dsNone: String { t("None", "Hiçbiri") }
    var dsCustomize: String { t("Customize", "Özelleştir") }
    var dashSectionsOff: String { t("Every dashboard section is turned off. Turn some on in Settings › Display › Dashboard.", "Dashboard'un bütün bölümleri kapalı. Ayarlar › Display › Dashboard'dan açabilirsin.") }

    var dashLast30Days: String { t("Last 30 days", "Son 30 gün") }
    func dashLastMonths(_ n: Int) -> String { t("Last \(n) months", "Son \(n) ay") }
    func dashMonthlyAverage(_ value: String) -> String { t("avg \(value) / month", "aylık ort. \(value)") }
    var dashCostFailed: String { t("Couldn't load cost", "Maliyet alınamadı") }
    var locale: Locale { Locale(identifier: self == .tr ? "tr_TR" : "en_US") }

    /// "November 2026" / "Kasım 2026" for a `YYYY-MM` key.
    func monthName(_ key: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM"
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let date = parser.date(from: key) else { return key }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f.string(from: date)
    }
    var dashSpendTrendMonthly: String { t("Monthly spend", "Aylık harcama") }

    var dsServicesLayout: String { t("Services", "Servisler") }
    func servicesLayoutLabel(_ layout: DashboardPrefs.ServicesLayout) -> String {
        layout == .categories ? t("By category", "Kategorilere göre") : t("One row", "Tek liste")
    }
    var dsServicesLayoutNote: String { t("By category: a block per AWS category. One row: every service icon together, most resources first. Favorites are always shown on top.", "Kategorilere göre: her AWS kategorisi ayrı blok. Tek liste: bütün servis ikonları bir arada, kaynağı en çok olan başta. Favoriler her zaman en üstte ayrıca gösterilir.") }
    var dashFavorites: String { t("Favorites", "Favoriler") }
    var dashAllServices: String { t("All services", "Tüm servisler") }
    var dashProfile: String { t("Profile", "Profil") }
    var dashRegion: String { t("Region", "Bölge") }
    var dashAccount: String { t("Account", "Hesap") }
    func dashResourceCount(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n == 1 ? t("1 resource", "1 kaynak") : t("\(n) resources", "\(n) kaynak")
    }
    var dashUpdatedTitle: String { t("Updated", "Güncellendi") }

    // MARK: Tooltips / Details

    var dashDetails: String { t("Details", "Details") }
    var dashClose: String { t("Close", "Kapat") }
    var dashTotal: String { t("Total", "Toplam") }
    var dashVsDailyAverage: String { t("vs daily average", "günlük ortalamaya göre") }
    var dashVsMonthlyAverage: String { t("vs monthly average", "aylık ortalamaya göre") }
    var dashVsDailyAverageShort: String { t("vs avg", "ort.'ya göre") }
    var dashVsMonthlyAverageShort: String { t("vs avg", "ort.'ya göre") }
    var dashShareOfPeriod: String { t("Share of period", "Dönemdeki payı") }
    var dashShareOfResources: String { t("Share of resources", "Kaynaklardaki payı") }
    var dashDailyAverageTitle: String { t("Daily average", "Günlük ortalama") }
    var dashMonthlyAverageTitle: String { t("Monthly average", "Aylık ortalama") }
    var dashNoBreakdown: String { t("No per-service breakdown for this point (refresh to load it).", "Bu nokta için servis kırılımı yok (yüklemek için yenile).") }
    var dashRank: String { t("Rank", "Sıra") }
    var dashPeakDay: String { t("Peak day", "En yüksek gün") }
    var dashPeakMonth: String { t("Peak month", "En yüksek ay") }

    // MARK: Refresh / saved data

    var dsRefresh: String { t("Refresh", "Yenileme") }
    var dsRefreshEvery: String { t("Fetch again after", "Yeniden çekme süresi") }
    var dsManual: String { t("Manual", "Manuel") }
    var dsCustom: String { t("Custom", "Özel") }
    var dsMinutes: String { t("minutes", "dakika") }
    var dsHours: String { t("hours", "saat") }
    func dsRefreshLabel(_ minutes: Int) -> String {
        if minutes == 0 { return dsManual }
        if minutes % 60 == 0 { return t("\(minutes / 60) h", "\(minutes / 60) sa") }
        return t("\(minutes) min", "\(minutes) dk")
    }
    var dsRefreshNote: String { t("The dashboard's data is saved in ~/.awsvisualizer. Opening the dashboard shows the saved data without calling AWS; it is fetched again only when older than this. Custom: 1 minute to 24 hours.", "Dashboard verisi ~/.awsvisualizer'da saklanır. Dashboard açılınca AWS'ye gitmeden saklanan veri gösterilir; yalnızca bu süreden eskiyse yeniden çekilir. Özel: 1 dakika ile 24 saat arası.") }
    var dsRefreshOnOpen: String { t("Fetch every time the dashboard opens", "Dashboard'a her girişte yeniden çek") }
    var dsRefreshOnOpenNote: String { t("Off by default: with it on, every visit makes the AWS calls again even if the saved data is fresh.", "Varsayılan kapalı: açıkken her girişte saklanan veri yeni olsa bile AWS istekleri tekrar yapılır.") }
    func dsRefreshInvalid(_ max: Int) -> String { t("Enter 1 minute to \(max / 60) hours.", "1 dakika ile \(max / 60) saat arası gir.") }
    func dashSavedAgo(_ text: String) -> String { t("saved \(text)", "\(text) kaydedildi") }
    var dashNextRefresh: String { t("next refresh", "sonraki yenileme") }

    // MARK: Cards

    var cardsTitle: String { t("My cards", "Kartlarım") }
    var cardsAdd: String { t("Add card", "Kart ekle") }
    var cardsEmpty: String { t("Add your own cards from any service: a number to watch (objects in an S3 folder, results of a DynamoDB query, open pull requests…), an action to run (open a pull request from one branch to another…) or a shortcut (a repository's history…). Drag to reorder.", "Herhangi bir servisten kendi kartlarını ekle: izlenecek bir sayı (S3 klasöründeki nesneler, DynamoDB sorgusunun sonuçları, açık pull request'ler…), çalıştırılacak bir aksiyon (bir daldan diğerine pull request açmak…) ya da bir kısayol (bir repository'nin geçmişi…). Sürükleyerek sıralayabilirsin.") }
    var cardsDragHint: String { t("Drag cards to reorder - the order is saved.", "Kartları sürükleyerek sırala - sıra kaydedilir.") }
    var cardEdit: String { t("Edit", "Düzenle") }
    var cardDelete: String { t("Delete", "Sil") }
    var cardRefresh: String { t("Refresh", "Yenile") }
    var cardNew: String { t("New card", "Yeni kart") }
    var cardEditTitle: String { t("Edit card", "Kartı düzenle") }
    var cardSave: String { t("Save", "Kaydet") }
    var cardCancel: String { t("Cancel", "Vazgeç") }
    var cardDeleteConfirm: String { t("Delete this card?", "Bu kart silinsin mi?") }
    var cardLimit: String { t("You can add at most 30 cards.", "En fazla 30 kart ekleyebilirsin.") }
    var cardInvalidTitle: String { t("Give the card a title.", "Karta bir başlık ver.") }
    var cardNotFetched: String { t("Not fetched yet", "Henüz çekilmedi") }
    var cardApproximate: String { t("approximate", "yaklaşık") }
    var cardTruncated: String { t("at least", "en az") }
    var cardsSettingsNote: String { t("Cards are also managed on the dashboard. A metric card's AWS request runs only while My cards is on; an action runs only when you click Run and confirm.", "Kartlar dashboard'dan da yönetilir. Metrik kartın AWS isteği yalnızca Kartlarım açıkken yapılır; aksiyon yalnızca Çalıştır'a basıp onaylayınca çalışır.") }

    func cardKindLabel(_ kind: CardTemplate.Kind) -> String {
        switch kind {
        case .metric: return t("Metric", "Metrik")
        case .action: return t("Action", "Aksiyon")
        case .link: return t("Shortcut", "Kısayol")
        case .note: return t("Note", "Not")
        }
    }

    func cardKindHint(_ kind: CardTemplate.Kind) -> String {
        switch kind {
        case .metric: return t("Shows a number; refreshed with the dashboard.", "Bir sayı gösterir; dashboard ile birlikte yenilenir.")
        case .action: return t("Does something on AWS - only when you click Run and confirm.", "AWS'de bir şey yapar - yalnızca Çalıştır'a basıp onaylayınca.")
        case .link: return t("Opens a screen of the app.", "Uygulamada bir ekranı açar.")
        case .note: return t("Your own text.", "Kendi metnin.")
        }
    }

    // Editor
    var cardStepService: String { t("1. Service", "1. Servis") }
    var cardStepType: String { t("2. Card type", "2. Kart türü") }
    var cardStepSettings: String { t("3. Settings", "3. Ayarlar") }
    var cardStepPreview: String { t("Preview of the selection", "Seçimin önizlemesi") }
    var cardSearchService: String { t("Search services", "Servis ara") }
    var cardNoteService: String { t("Note (no service)", "Not (servis yok)") }
    var cardSelectedServices: String { t("Your services", "Servislerin") }
    var cardOtherServices: String { t("Other services", "Diğer servisler") }
    var cardLoadingTypes: String { t("Loading card types…", "Kart türleri yükleniyor…") }
    var cardTitleField: String { t("Card title", "Kart başlığı") }
    var cardProfile: String { t("Profile", "Profil") }
    var cardRegion: String { t("Region", "Bölge") }
    var cardRunParams: String { t("Asked every time it runs", "Her çalıştırmada sorulur") }
    var cardRunParamsHint: String { t("What you type here is the default; you can change it on each run.", "Buraya yazdığın varsayılan olur; her çalıştırmada değiştirebilirsin.") }
    var cardLinkContextHint: String { t("Shortcuts open in the profile and region you're using at the time.", "Kısayollar o anda kullandığın profil ve bölgede açılır.") }
    var cardChooseFirst: String { t("Choose a service and a card type.", "Bir servis ve kart türü seç.") }
    var cardOptionsLoading: String { t("Loading…", "Yükleniyor…") }
    var cardOptionsEmpty: String { t("Nothing to choose", "Seçilecek bir şey yok") }
    func cardWaitFor(_ fields: String) -> String { t("Choose \(fields) first", "Önce \(fields) seç") }
    var cardPreviewWaiting: String { t("Fill in the required fields to see the data.", "Veriyi görmek için gerekli alanları doldur.") }
    var cardPreviewLoading: String { t("Loading the data…", "Veri yükleniyor…") }
    var cardPreviewMore: String { t("More rows exist.", "Daha fazla satır var.") }
    var cardPreviewNone: String { t("This card type has no preview.", "Bu kart türünün önizlemesi yok.") }

    // Dynamo query builder
    var qbTarget: String { t("Query on", "Sorgulanacak") }
    var qbPartition: String { t("Partition key", "Partition key") }
    var qbSort: String { t("Sort key", "Sort key") }
    var qbFilters: String { t("Filters", "Filtreler") }
    var qbAddFilter: String { t("Add condition", "Koşul ekle") }
    var qbAttribute: String { t("Attribute", "Özellik") }
    var qbValue: String { t("Value", "Değer") }
    var qbValues: String { t("Values, comma separated", "Değerler, virgülle") }
    var qbStatement: String { t("Resulting query", "Oluşan sorgu") }
    var qbChooseTable: String { t("Choose a table first.", "Önce bir tablo seç.") }
    func qbSortOp(_ op: String) -> String {
        switch op {
        case "none": return t("Any", "Hepsi")
        case "begins_with": return t("Begins with", "İle başlar")
        case "between": return t("Between", "Arasında")
        default: return op
        }
    }
    func qbMatch(_ op: FilterMatchOperator) -> String {
        switch op {
        case .equal: return t("Equals", "Eşittir")
        case .notEqual: return t("Not equal", "Eşit değil")
        case .contains: return t("Contains", "İçerir")
        case .onlyBlankNullNone: return t("Is blank / null", "Boş / null")
        case .notBlankNullNone: return t("Is not blank", "Boş değil")
        case .isIn: return t("Is one of", "Şunlardan biri")
        }
    }

    // Running / opening
    var cardRun: String { t("Run", "Çalıştır") }
    var cardOpen: String { t("Open", "Aç") }
    var cardRunTitle: String { t("Run action", "Aksiyonu çalıştır") }
    var cardRunConfirm: String { t("Run now", "Şimdi çalıştır") }
    var cardRunning: String { t("Running…", "Çalışıyor…") }
    var cardLastRun: String { t("Last run", "Son çalıştırma") }
    var cardNeverRun: String { t("Not run yet", "Henüz çalıştırılmadı") }
    var cardRunWarning: String { t("This changes your AWS account and can't be undone from here.", "Bu, AWS hesabında değişiklik yapar ve buradan geri alınamaz.") }
    var cardOpenResult: String { t("Show", "Göster") }

    // MARK: Default services page

    var defaultsTitle: String { t("Default services", "Varsayılan servisler") }
    var defaultsNote: String { t("The services picked on first sign-in. \"Select default\" in the services list selects these, and their packages are installed when missing. Saved with Save Changes; missing packages are offered for install right after.", "İlk girişte seçilen servisler. Servis listesindeki \"Select default\" bunları seçer ve paketleri eksikse kurulur. Save Changes ile kaydedilir; eksik paketler hemen ardından kurulum için önerilir.") }

    // MARK: Cards - picker, profiles, opening

    var cardClickToOpen: String { t("Click to open where this data lives", "Verinin bulunduğu yeri açmak için tıkla") }
    var cardShowOtherServices: String { t("Show other services", "Diğer servisleri göster") }
    var cardHideOtherServices: String { t("Hide other services", "Diğer servisleri gizle") }
    var cardChangeService: String { t("Change", "Değiştir") }
    var cardAllProfiles: String { t("Show on every profile", "Bütün profillerde göster") }
    var cardAllProfilesHintAWS: String { t("Runs with the profile and region in use at the time.", "O anda kullanılan profil ve bölgeyle çalışır.") }
    var cardAllProfilesHint: String { t("Shown whichever profile is in use.", "Hangi profil kullanılıyorsa orada görünür.") }
    func cardOnlyProfile(_ profile: String) -> String { t("Only on \(profile)'s dashboard.", "Yalnızca \(profile) profilinin dashboard'unda.") }
    var cardScopeAll: String { t("All profiles", "Bütün profiller") }
    var cardPrefilling: String { t("Filling from the last commit…", "Son commit'ten dolduruluyor…") }

    // MARK: Spend chart

    func chartStyleLabel(_ style: DashboardPrefs.ChartStyle) -> String {
        switch style {
        case .bar: return t("Bars", "Çubuk")
        case .line: return t("Lines", "Çizgi")
        case .points: return t("Points", "Nokta")
        }
    }
    var dsChartStyle: String { t("Chart style", "Grafik tipi") }
    var dashAverageShort: String { t("Avg.", "Ort.") }
    var dashSpend: String { t("Spend", "Harcama") }
    var dashDayAxis: String { t("Day", "Gün") }
    var dashMonthAxis: String { t("Month", "Ay") }
    var dashPrevious: String { t("Previous", "Önceki") }
    var dashSelected: String { t("Selected", "Seçili") }
    var dashChange: String { t("Change", "Değişim") }

    // MARK: DynamoDB search builder

    func qbMode(_ mode: String) -> String {
        switch mode {
        case "scan": return t("Filter (whole table)", "Filtre (bütün tablo)")
        case "partiql": return t("PartiQL", "PartiQL")
        default: return t("Query", "Query")
        }
    }
    func qbModeHint(_ mode: String) -> String {
        switch mode {
        case "scan": return t("Filter Builder conditions searched over the whole table - like the grid's search. Reads every item.", "Filter Builder koşulları bütün tabloda aranır - tablodaki arama gibi. Her kaydı okur.")
        case "partiql": return t("A PartiQL SELECT statement, like the PartiQL console. Only SELECT is allowed on a card.", "PartiQL konsolundaki gibi bir SELECT ifadesi. Kartta yalnızca SELECT kullanılabilir.")
        default: return t("Partition key (and sort key) on the table or an index, plus Filter Builder conditions - like the Query form. Reads only that partition.", "Tabloda ya da index'te partition key (ve sort key), artı Filter Builder koşulları - Query formu gibi. Yalnızca o partition'ı okur.")
        }
    }
    var qbNoFilter: String { t("No filter - every item of the partition.", "Filtre yok - partition'daki her kayıt.") }
    var qbNoFilterScan: String { t("Add at least one filter condition.", "En az bir filtre koşulu ekle.") }
    var qbEditFilter: String { t("Edit filter", "Filtreyi düzenle") }
    var qbClearFilter: String { t("Clear filter", "Filtreyi temizle") }
    var qbPartiql: String { t("Statement", "İfade") }
    var qbPartiqlHint: String { t("Starts with SELECT; one statement.", "SELECT ile başlar; tek ifade.") }
    var qbSetUp: String { t("Set up the search.", "Aramayı oluştur.") }

    // MARK: Cards - scope, edit window, run

    var cardProfiles: String { t("Shown on", "Gösterileceği profiller") }
    var cardProfilesHint: String { t("The card runs with the profile in use, so it is only shown where you picked it.", "Kart o anda kullanılan profille çalışır; bu yüzden yalnızca seçtiğin profillerde görünür.") }
    var cardCurrent: String { t("(in use)", "(şu an)") }
    var cardCurrentRegion: String { t("Region in use", "O anki bölge") }
    var cardChooseProfiles: String { t("Pick at least one profile, or show it on every profile.", "En az bir profil seç ya da bütün profillerde göster.") }
    func cardScopeCount(_ n: Int) -> String { t("\(n) profiles", "\(n) profil") }
    var cardsEditTitle: String { t("Edit cards", "Kartları düzenle") }
    var cardRunMetricHelp: String { t("Run: open the results in the service", "Çalıştır: sonuçları serviste aç") }

    // MARK: Sections

    var dashSections: String { t("Sections", "Bölümler") }
    var dashSectionsHint: String { t("Applied right away: a section turned on loads its data, one turned off sends no requests.", "Hemen uygulanır: açılan bölüm verisini yükler, kapatılan bölüm istek göndermez.") }
    func dashLoadingCounts(done: Int, total: Int) -> String { t("\(done) / \(total) loaded", "\(done) / \(total) yüklendi") }

    var filterPrompt: String { t("Filter", "Filtrele") }

    // MARK: About

    var aboutTitle: String { t("About", "Hakkında") }
    var aboutApp: String { t("App", "Uygulama") }
    var aboutApi: String { t("Local API", "Yerel API") }
    func aboutMismatch(app: String, api: String) -> String {
        t("The local API is \(api) but the app is \(app) - restart the app so both run the same version.", "Yerel API \(api), uygulama ise \(app) - ikisinin aynı sürümde çalışması için uygulamayı yeniden başlat.")
    }
}
