import Foundation
import Testing
@testable import DoveKit

struct DownloadNoticesTests {
    private func record(_ name: String, _ state: DownloadRecord.State, written: Int64 = 0, total: Int64? = nil, id: String = UUID().uuidString) -> DownloadRecord {
        DownloadRecord(id: id, backend: .torBox, itemID: "1", fileID: "f", name: name, state: state, bytesWritten: written, totalBytes: total)
    }

    @Test func plainDownloadsNotifyOnFinishAndFailure() {
        let done = DownloadNotices.notice(for: record("Show/Movie.2020.mkv", .finished, written: 2_000_000_000, total: 2_000_000_000), job: nil)
        #expect(done?.title == "Downloaded")
        #expect(done?.body.hasPrefix("Movie.2020.mkv · ") == true)
        let failed = DownloadNotices.notice(for: record("Movie.mkv", .failed(reason: "The link expired")), job: nil)
        #expect(failed?.title == "Download failed")
        #expect(failed?.body == "Movie.mkv: The link expired")
        #expect(DownloadNotices.notice(for: record("Movie.mkv", .downloading), job: nil) == nil)
        #expect(DownloadNotices.notice(for: record("Movie.mkv", .paused), job: nil) == nil)
    }

    @Test func jobFilesReportOnlyFailuresAndTheJobReportsTheEnd() {
        let job = DownloadJob(backend: .torBox, itemID: "1", name: "Show.S01.1080p", pick: .allVideos)
        #expect(DownloadNotices.notice(for: record("E01.mkv", .finished), job: job) == nil)
        #expect(DownloadNotices.notice(for: record("E01.mkv", .failed(reason: "x")), job: job)?.title == "Download only: Show.S01.1080p")
        let finished = DownloadNotices.notice(for: job, outcome: .finished(files: 8))
        #expect(finished.title == "On your iPhone")
        #expect(finished.body == "Show.S01.1080p\n8 files · removed from TorBox")
        #expect(DownloadNotices.notice(for: job, outcome: .finished(files: 1)).body == "Show.S01.1080p\nremoved from TorBox")
        #expect(DownloadNotices.notice(for: job, outcome: .failed(reason: "Nope")).title == "Download only stopped")
    }

    @Test func activitySummaryCoversWhatItHasShown() {
        let old = record("Old.mkv", .finished, written: 900, total: 900, id: "old")
        let a = record("A.mkv", .downloading, written: 100, total: 1000, id: "a")
        let b = record("B.mkv", .downloading, written: 0, total: 3000, id: "b")
        var summary = DownloadActivitySummary(records: [old, a, b], covering: ["a", "b"])
        #expect(summary.active == 2)
        #expect(summary.finished == 0)
        #expect(summary.current == "B.mkv")
        #expect(summary.fraction == 0.025)
        #expect(summary.status == "2 downloading")

        let doneA = record("A.mkv", .finished, written: 1000, total: 1000, id: "a")
        let next = DownloadActivitySummary(records: [old, doneA, b], covering: ["a", "b"])
        #expect(next.fraction == 0.25, "a finished file stays in the totals")
        #expect(next.status == "1 downloading · 1 done")
        #expect(next.differs(from: summary))

        summary = DownloadActivitySummary(records: [doneA, record("B.mkv", .failed(reason: "x"), id: "b")], covering: ["a", "b"])
        #expect(summary.isDone)
        #expect(summary.status == "1 file downloaded · 1 failed")
    }

    @Test func unknownSizesHaveNoFractionAndSmallMovesAreNotPushed() {
        let a = DownloadActivitySummary(records: [record("A.mkv", .downloading, written: 10, total: nil, id: "a")], covering: ["a"])
        #expect(a.fraction == nil)
        let b = DownloadActivitySummary(records: [record("A.mkv", .downloading, written: 500, total: 100_000, id: "a")], covering: ["a"])
        let c = DownloadActivitySummary(records: [record("A.mkv", .downloading, written: 900, total: 100_000, id: "a")], covering: ["a"])
        #expect(!c.differs(from: b))
        #expect(a.differs(from: b))
    }
}
