//
//  FileChangeWatcher.swift
//  Liney
//
//  Author: everettjf
//

import Foundation

/// Watches a single file for content changes and invokes a handler on the main
/// queue. Used to live-reload the preview panel when an AI tool (or the user)
/// rewrites the file being viewed.
///
/// Editors frequently replace a file via rename rather than writing in place, so
/// the watcher re-arms itself after delete/rename events by re-opening the path.
final class FileChangeWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.everettjf.liney.fileChangeWatcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var rearmWorkItem: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        stop()
    }

    private func start() {
        queue.async { [weak self] in
            self?.arm()
        }
    }

    private func arm() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // File may not exist yet; retry shortly.
            scheduleRearm()
            return
        }
        fileDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link, .attrib],
            queue: queue
        )
        self.source = source

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            DispatchQueue.main.async { self.onChange() }
            // A delete/rename invalidates the descriptor — re-open the path so
            // we keep tracking the new inode.
            if events.contains(.delete) || events.contains(.rename) {
                self.disarm()
                self.scheduleRearm()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        source.resume()
    }

    private func disarm() {
        source?.cancel()
        source = nil
    }

    private func scheduleRearm() {
        rearmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.arm()
        }
        rearmWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func stop() {
        rearmWorkItem?.cancel()
        rearmWorkItem = nil
        source?.cancel()
        source = nil
    }
}
