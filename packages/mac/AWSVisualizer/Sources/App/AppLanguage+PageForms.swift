import Foundation

/// Text of the ResourcePage forms (G1) and the CloudWatch graphs (G2).
extension AppLanguage {
    var formCancel: String { self == .tr ? "Vazgeç" : "Cancel" }
    var formFixFields: String { self == .tr ? "Devam etmek için işaretli alanları düzeltin." : "Fix the marked fields to continue." }
    var formIrreversible: String { self == .tr ? "Bu işlem AWS'de gerçekten yapılır." : "This really happens on AWS." }

    var metricsRange: String { self == .tr ? "Aralık" : "Range" }
    var metricsNoData: String { self == .tr ? "Bu aralıkta veri yok" : "No data in this range" }
    var metricsLoading: String { self == .tr ? "Metrikler yükleniyor…" : "Loading metrics…" }
    var metricsRefresh: String { self == .tr ? "Grafikleri yenile" : "Refresh graphs" }

    func metricsPeriod(_ seconds: Int) -> String {
        let text = seconds >= 3600 ? "\(seconds / 3600) h" : seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
        return self == .tr ? "Her nokta \(text)" : "\(text) per point"
    }

    func metricRangeTitle(_ range: MetricRange) -> String {
        switch (range, self) {
        case (.hour1, .tr): "1 sa"
        case (.hours3, .tr): "3 sa"
        case (.hours12, .tr): "12 sa"
        case (.day1, .tr): "1 g"
        case (.days3, .tr): "3 g"
        case (.week1, .tr): "1 hf"
        case (.hour1, _): "1h"
        case (.hours3, _): "3h"
        case (.hours12, _): "12h"
        case (.day1, _): "1d"
        case (.days3, _): "3d"
        case (.week1, _): "1w"
        }
    }
}
