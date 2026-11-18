import Foundation

/// Text of Settings › Platforms › Profiles (sign-in state, delete).
extension AppLanguage {
    private func p(_ en: String, _ tr: String) -> String { self == .tr ? tr : en }

    var profilesTitle: String { p("Profiles", "Profiller") }
    var profilesHint: String {
        p("Every profile in ~/.aws/config. A login made in a terminal (aws sso login) is picked up automatically.",
          "~/.aws/config'teki tüm profiller. Terminalden yapılan giriş (aws sso login) otomatik algılanır.")
    }
    var profilesCurrent: String { p("in use", "kullanımda") }
    var profilesSignedIn: String { p("Signed in", "Giriş yapılmış") }
    func profilesSignedInUntil(_ time: String) -> String { p("Signed in · until \(time)", "Giriş yapılmış · \(time)'e kadar") }
    var profilesExpired: String { p("Session expired", "Oturum süresi dolmuş") }
    var profilesUnverified: String { p("Couldn't reach AWS to check - assumed signed in", "Kontrol için AWS'ye ulaşılamadı - giriş yapılmış sayıldı") }
    var profilesLogIn: String { p("Log in", "Giriş yap") }
    var profilesRecheck: String { p("Check again", "Tekrar kontrol et") }
    var profilesDelete: String { p("Delete profile", "Profili sil") }
    func profilesDeleteMessage(_ name: String) -> String {
        p("Profile \"\(name)\" will be removed from ~/.aws/config (and ~/.aws/credentials). A backup is kept as config.awsvisualizer.bak. Are you sure?",
          "\"\(name)\" profili ~/.aws/config'ten (ve ~/.aws/credentials'tan) silinecek. Yedeği config.awsvisualizer.bak olarak saklanır. Emin misiniz?")
    }
    var profilesEmpty: String { p("No profiles in ~/.aws/config yet.", "~/.aws/config'te henüz profil yok.") }
}
