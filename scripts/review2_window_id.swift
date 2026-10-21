// Print the window number of the frontmost normal window owned by an app
// (default "Terminal"), for `screencapture -l <number>`.
//
//   swiftc -O scripts/review2_window_id.swift -o <dir>/review2_window_id
//   <dir>/review2_window_id [AppName]          -> e.g. 4711, exit 1 if none
//   <dir>/review2_window_id --list             -> owner and number of on-screen windows
//
// Owner names and window numbers are readable without Screen Recording
// permission; only the capture itself (screencapture) needs it.

import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(2)
}
if args.first == "--list" {
    for w in info {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let number = w[kCGWindowNumber as String] as? Int ?? -1
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        print("\(number)\tlayer \(layer)\t\(owner)")
    }
    exit(0)
}
let app = args.first ?? "Terminal"
// The list is ordered front to back, so the first match is the frontmost.
for w in info {
    if (w[kCGWindowOwnerName as String] as? String) == app,
       (w[kCGWindowLayer as String] as? Int) == 0,
       let number = w[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)
