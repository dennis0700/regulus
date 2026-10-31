// 把 SVG 图标渲染成 macOS 的 .icns：用 NSImage 渲染 iconset 的 10 个尺寸，再交给 iconutil
// Turn the SVG icon into a macOS .icns: render the 10 iconset sizes with NSImage, then run iconutil.
//
// 由 project.yml 的构建阶段调用，也可以手动运行 / Run by the build phase in project.yml, or by hand:
//   swift scripts/make_icon.swift assets/AppIcon.svg AppIcon.icns
//
// 注意：NSImage 遇到 XML 注释会加载失败，SVG 里不要写注释
// Note: NSImage fails to load SVGs containing XML comments, so keep the SVG comment-free.
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(1)
}

func render(_ image: NSImage, size: Int, to url: URL) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("cannot create a \(size)px bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("cannot encode \(size)px PNG") }
    do { try png.write(to: url) } catch { fail("cannot write \(url.path): \(error)") }
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: make_icon.swift <icon.svg> <output.icns>") }
let svg = URL(fileURLWithPath: args[1])
let icns = URL(fileURLWithPath: args[2])
guard let image = NSImage(contentsOf: svg) else { fail("cannot load \(svg.path)") }

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
do {
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    try fm.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch { fail("\(error)") }
defer { try? fm.removeItem(at: iconset) }

// iconutil 要求的文件名：icon_<点数>x<点数>[@2x].png / The file names iconutil expects.
for points in [16, 32, 128, 256, 512] {
    render(image, size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    render(image, size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
do { try iconutil.run() } catch { fail("cannot run iconutil: \(error)") }
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed (\(iconutil.terminationStatus))") }
