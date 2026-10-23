/// Temporarily hide explicit song downloads while validation issue D001 is
/// investigated. This is presentation policy only: cached/retained audio,
/// download records, AutoMix acquisition and stem model downloads are intact.
enum SongDownloadUI {
    static let isAvailable = false
}
