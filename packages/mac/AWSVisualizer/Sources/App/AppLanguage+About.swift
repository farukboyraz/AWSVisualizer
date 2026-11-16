import Foundation

/// Settings › About.
extension AppLanguage {
    private func a(_ en: String, _ tr: String) -> String { self == .tr ? tr : en }

    var aboutPageTitle: String { a("About", "Hakkında") }
    var aboutPageSubtitle: String { a("Version, privacy, what the app does and doesn't do, and where things are.", "Sürüm, gizlilik, uygulamanın yaptıkları ve yapmadıkları, nerede ne olduğu.") }
    var aboutTagline: String { a("A native macOS app to see and manage your AWS accounts - running entirely on your Mac.", "AWS hesaplarını görmek ve yönetmek için native bir macOS uygulaması - tamamen senin Mac'inde çalışır.") }

    // Privacy
    var aboutPrivacyTitle: String { a("Local only - nothing is shared", "Yalnızca yerel - hiçbir şey paylaşılmaz") }
    var aboutPrivacyPoints: [String] {
        [
            a("The app and its local API (Node.js + the AWS SDK) run on this Mac.", "Uygulama ve yerel API'si (Node.js + AWS SDK) bu Mac'te çalışır."),
            a("It talks to AWS directly, with the profiles in your ~/.aws - no server, proxy or account of ours in between.", "AWS ile doğrudan, ~/.aws içindeki profillerinle konuşur - arada bize ait bir sunucu, proxy ya da hesap yoktur."),
            a("No telemetry, analytics or crash reports; your data isn't sent or copied anywhere.", "Telemetri, analitik ya da hata raporu yok; verilerin hiçbir yere gönderilmez ya da kopyalanmaz."),
            a("The local API listens on 127.0.0.1 only and accepts only this app (a secret made at every launch).", "Yerel API yalnızca 127.0.0.1'i dinler ve yalnızca bu uygulamayı kabul eder (her açılışta üretilen gizli anahtar)."),
            a("Other downloads happen only when you ask: Node.js (nodejs.org), nvm (GitHub) and service packages (npm).", "Başka indirmeler yalnızca sen istediğinde olur: Node.js (nodejs.org), nvm (GitHub) ve servis paketleri (npm)."),
        ]
    }

    // Features
    var aboutHasTitle: String { a("What's in it", "Neler var") }
    var aboutOpen: String { a("Open", "Aç") }
    struct AboutFeature { let icon: String; let title: String; let detail: String; let page: SettingsPage? }
    var aboutFeatures: [AboutFeature] {
        [
            .init(icon: "square.grid.3x3.fill", title: a("161 AWS services", "161 AWS servisi"), detail: a("Every service of the AWS catalog: lists, detail pages, tags and the common actions; retired services as info pages.", "AWS kataloğundaki her servis: listeler, detay sayfaları, etiketler ve sık işlemler; kapanan servisler bilgi sayfası olarak."), page: .services),
            .init(icon: "rectangle.3.group.fill", title: a("Dashboard", "Dashboard"), detail: a("Resources by service and category, spend by day / month with Cost Explorer, favorites - each section can be switched off.", "Servis ve kategoriye göre kaynaklar, Cost Explorer ile günlük / aylık harcama, favoriler - her bölüm kapatılabilir."), page: .dashboard),
            .init(icon: "rectangle.stack.badge.person.crop.fill", title: a("Your own cards", "Kendi kartların"), detail: a("Saved searches with their count and a Run button (e.g. a DynamoDB query), actions (open a pull request), shortcuts - per profile.", "Sayısı ve Run butonuyla kayıtlı aramalar (ör. DynamoDB sorgusu), aksiyonlar (pull request açmak), kısayollar - profil bazında."), page: .dashboard),
            .init(icon: "person.2.badge.key.fill", title: a("Several accounts", "Birden fazla hesap"), detail: a("SSO access portals and every profile of ~/.aws; switch profile and region at any time.", "SSO erişim portalları ve ~/.aws'teki her profil; profil ve bölge istediğin an değişir."), page: .platforms),
            .init(icon: "shippingbox.fill", title: a("Node.js & packages", "Node.js ve paketler"), detail: a("Checks Node.js / npm, installs them if you want (pkg, nvm or app-only), and installs each service's AWS SDK package only when you use it.", "Node.js / npm'i kontrol eder, istersen kurar (pkg, nvm ya da yalnızca uygulamaya özel) ve her servisin AWS SDK paketini yalnızca kullandığında kurar."), page: .runtime),
            .init(icon: "paintbrush.fill", title: a("Look and layout", "Görünüm ve yerleşim"), detail: a("Light / dark, side by side or single page, file icons, code colors, button colors.", "Açık / koyu, yan yana ya da tek sayfa, dosya ikonları, kod renkleri, buton renkleri."), page: .display),
            .init(icon: "hammer.fill", title: a("Developer tools", "Geliştirici araçları"), detail: a("A terminal panel and CLI tools next to your work, and \"Open in\" your IDE.", "İşinin yanında terminal paneli ve CLI araçları, IDE'de \"Aç\"."), page: .developer),
            .init(icon: "character.bubble.fill", title: a("English and Turkish", "Türkçe ve İngilizce"), detail: a("Messages, warnings and the dashboard in the language you pick.", "Mesajlar, uyarılar ve dashboard seçtiğin dilde."), page: .general),
        ]
    }

    // Not (yet) in it
    var aboutHasNotTitle: String { a("Not in it (yet)", "Henüz olmayanlar") }
    var aboutHasNot: [String] {
        [
            a("macOS only - Windows, iOS and Android are planned.", "Yalnızca macOS - Windows, iOS ve Android planlı."),
            a("Not every service can create or delete everything; most offer viewing, tags and selected actions.", "Her servis her şeyi oluşturup silemez; çoğunda görüntüleme, etiketler ve seçili işlemler var."),
            a("No credentials of its own: sign-in is the AWS CLI v2 (aws sso login) and your ~/.aws.", "Kendi kimlik bilgisi yok: giriş AWS CLI v2 (aws sso login) ve ~/.aws ile yapılır."),
            a("Kiro usage reports and permission / policy management are being researched.", "Kiro kullanım raporu ve yetki / politika yönetimi araştırma aşamasında."),
            a("Not signed or notarized for distribution - it is built from source on your Mac.", "Dağıtım için imzalı / notarize değil - kaynaktan, kendi Mac'inde derlenir."),
            a("Cost Explorer requests are billed by AWS (about $0.01 each); the dashboard caches them.", "Cost Explorer istekleri AWS tarafından ücretlendirilir (her biri yaklaşık $0.01); dashboard bunları saklar."),
        ]
    }

    // Places
    var aboutPlacesTitle: String { a("Where things are", "Nerede ne var") }
    var aboutSettingsFile: String { a("Settings file", "Ayar dosyası") }
    var aboutPackagesFolder: String { a("Service packages", "Servis paketleri") }
    var aboutApiLog: String { a("Local API log", "Yerel API log'u") }
    var aboutReadme: String { a("README", "README") }
    var aboutProjectPage: String { a("Project page", "Proje sayfası") }
    var aboutShowInFinder: String { a("Show in Finder", "Finder'da göster") }
    var aboutViewRaw: String { a("View", "Görüntüle") }
    var aboutNotFound: String { a("not created yet", "henüz oluşturulmadı") }
}
