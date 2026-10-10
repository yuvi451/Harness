import CoreGraphics

/// Reads only the existing one-shot image. Finds the first substantial content
/// pane bounded by long, thin dividers; narrow navigation/editor gutters are skipped.
enum PaneLocator {
    static func locate(in image: CGImage) -> CGRect? {
        guard image.width >= 200, image.height >= 100, image.width <= 16_384,
              image.height <= 16_384, image.width <= 64_000_000 / image.height else { return nil }
        let scale = min(1, 1800.0 / Double(image.width), 1200.0 / Double(image.height))
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Filter while shrinking so a one-pixel divider cannot disappear between samples.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func divider(_ x: Int, _ y: Int) -> Int {
            let center = (y * width + x) * 4, left = center - 24, right = center + 24
            var contrast = 0, neighbors = 0
            for c in 0..<3 {
                let a = Int(pixels[center+c]) - Int(pixels[left+c])
                let b = Int(pixels[center+c]) - Int(pixels[right+c])
                // A thin line differs in the same direction from both sides.
                if a * b > 0 { contrast = max(contrast, min(abs(a),abs(b))) }
                neighbors = max(neighbors,abs(Int(pixels[left+c]) - Int(pixels[right+c])))
            }
            // Persistent faint seams survive the run-length gate even after
            // Retina downsampling. Strong-only edges miss light-theme rails.
            return contrast >= 3 ? 1 : neighbors >= 3 ? 2 : 0
        }
        var lines: [(x: Int, top: Int, bottom: Int, last: Int, count: Int, thin: Int, strength: Int)] = []
        for x in 6..<(width - 6) {
            if Task.isCancelled { return nil }
            var start = 0, last = -1, count = 0, top = height, bottom = 0, total = 0, thin = 0, totalThin = 0, longest = 0, strength = 0
            func finishRun() {
                longest = max(longest,count)
                if count >= height / 10 { top = min(top, start); bottom = max(bottom, last + 1); total += count; totalThin += thin }
                count = 0; thin = 0
            }
            for y in 0..<height {
                let kind = divider(x,y)
                if kind > 0 {
                    if count == 0 { start = y }
                    count += 1; last = y; if kind == 1 { thin += 1 }
                    let center = (y * width + x) * 4
                    for c in 0..<3 { strength += max(abs(Int(pixels[center+c])-Int(pixels[center+c-4])),abs(Int(pixels[center+c])-Int(pixels[center+c+4]))) }
                } else if count > 0, y - last > 3 { finishRun() }
            }
            finishRun()
            guard total >= height / 4, longest >= height / 4 else { continue }
            if let previous = lines.last, x - previous.last <= 6 {
                // Edge and center columns describe the same divider. Preserve its full span.
                let better = totalThin > previous.thin || totalThin == previous.thin &&
                    (strength > previous.strength || strength == previous.strength && total > previous.count)
                lines[lines.count-1] = (better ? x : previous.x,
                    min(top,previous.top),max(bottom,previous.bottom),x,max(total,previous.count),max(totalThin,previous.thin),max(strength,previous.strength))
                continue
            }
            lines.append((x,top,bottom,x,total,totalThin,strength))
        }
        // A cropped/full-screen view can start inside its content pane. Only a
        // real thin separator permits this edge; a desktop/window color boundary does not.
        if let first = lines.first, first.x >= width / 5, first.thin >= height * 35 / 100 {
            lines.insert((0,first.top,first.bottom,0,first.count,first.thin,first.strength),at:0)
        }
        // A short sidebar separator can border a single, full-width content pane.
        if lines.count == 1, let first = lines.first, first.x < width / 5 {
            lines.append((width,first.top,height,width,first.count,first.thin,first.strength))
        }
        for (left,right) in zip(lines, lines.dropFirst()) {
            let span = right.x - left.x
            let top = max(left.top,right.top), bottom = max(left.bottom,right.bottom)
            guard span >= max(160, width / 5), span <= width * 9 / 10 || right.x == width,
                  min(left.bottom,right.bottom) - top >= height / 4 else { continue }
            let inset = left.x == 0 ? 0 : 1
            return CGRect(x: Double(left.x + inset) / Double(width), y: Double(top) / Double(height),
                          width: Double(span - inset - 1) / Double(width), height: Double(bottom - top) / Double(height))
        }
        return nil
    }

    /// Normalized screenshot coordinates are top-left; AppKit coordinates are bottom-left.
    static func screenRect(_ pane: CGRect, capturedBounds: CGRect, displayCG: CGRect, displayAppKit: CGRect) -> CGRect {
        let sx = displayAppKit.width / displayCG.width, sy = displayAppKit.height / displayCG.height
        let x = capturedBounds.minX + pane.minX * capturedBounds.width
        let y = capturedBounds.minY + pane.maxY * capturedBounds.height
        return CGRect(x: displayAppKit.minX + (x - displayCG.minX) * sx,
                      y: displayAppKit.maxY - (y - displayCG.minY) * sy,
                      width: pane.width * capturedBounds.width * sx, height: pane.height * capturedBounds.height * sy)
    }
}
