import AppKit

let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 212, yRadius: 212)
NSColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1).setFill()
background.fill()
let stroke = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 204, yRadius: 204)
stroke.lineWidth = 3
NSColor(white: 1, alpha: 0.08).setStroke()
stroke.stroke()
func tile(_ y: CGFloat, _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 218, y: y + 115))
    path.line(to: NSPoint(x: 512, y: y + 273))
    path.line(to: NSPoint(x: 806, y: y + 115))
    path.line(to: NSPoint(x: 512, y: y - 43))
    path.close()
    path.lineJoinStyle = .round
    color.setFill(); path.fill()
}
tile(276, NSColor(red: 0.24, green: 0.34, blue: 0.24, alpha: 1))
tile(386, NSColor(red: 0.40, green: 0.53, blue: 0.30, alpha: 1))
tile(496, NSColor(red: 0.67, green: 0.81, blue: 0.42, alpha: 1))
let code = NSBezierPath()
code.move(to: NSPoint(x: 439, y: 550)); code.line(to: NSPoint(x: 390, y: 604)); code.line(to: NSPoint(x: 439, y: 654))
code.move(to: NSPoint(x: 585, y: 550)); code.line(to: NSPoint(x: 634, y: 604)); code.line(to: NSPoint(x: 585, y: 654))
code.move(to: NSPoint(x: 488, y: 545)); code.line(to: NSPoint(x: 536, y: 664))
code.lineWidth = 20; code.lineCapStyle = .round; code.lineJoinStyle = .round
NSColor(red: 0.10, green: 0.16, blue: 0.10, alpha: 1).setStroke(); code.stroke()
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
