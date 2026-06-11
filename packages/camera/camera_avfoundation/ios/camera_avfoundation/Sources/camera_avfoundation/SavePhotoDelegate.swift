// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import Flutter
import Foundation
import ImageIO

/// The completion handler block for save photo operations.
/// Can be called from either main queue or IO queue.
/// If success, `path` will be present and `error` will be nil. Otherwise, `path` will be nil and
/// `error` will be present.
/// path - the path for successfully saved photo file.
/// error - photo capture error or IO error.
typealias SavePhotoDelegateCompletionHandler = (String?, Error?) -> Void

/// Delegate object that handles photo capture results.
class SavePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  /// The file path for the captured photo.
  private let path: String

  /// The queue on which captured photos are written to disk.
  private let ioQueue: DispatchQueue

  /// When set, captured photos are downscaled so their longest side is at most
  /// this many pixels before being written to disk (see `downscaled`). `nil`
  /// writes the capture as-is.
  private let maxPixelSize: Int?

  /// The completion handler block for capture and save photo operations.
  let completionHandler: SavePhotoDelegateCompletionHandler

  /// The path for captured photo file.
  /// Exposed for unit tests to verify the captured photo file path.
  var filePath: String {
    path
  }

  /// Initialize a photo capture delegate.
  /// path - the path for captured photo file.
  /// ioQueue - the queue on which captured photos are written to disk.
  /// completionHandler - The completion handler block for save photo operations. Can
  /// be called from either main queue or IO queue.
  init(
    path: String,
    ioQueue: DispatchQueue,
    maxPixelSize: Int? = nil,
    completionHandler: @escaping SavePhotoDelegateCompletionHandler
  ) {
    self.path = path
    self.ioQueue = ioQueue
    self.maxPixelSize = maxPixelSize
    self.completionHandler = completionHandler
    super.init()
  }

  /// Handler to write captured photo data into a file.
  /// - Parameters:
  ///   - error: The capture error
  ///   - photoDataProvider: A closure that provides photo data
  func handlePhotoCaptureResult(
    error: Error?,
    photoDataProvider: @escaping () -> WritableData?
  ) {
    if let error = error {
      completionHandler(nil, error)
      return
    }

    ioQueue.async { [weak self] in
      guard let strongSelf = self else { return }

      do {
        let data = photoDataProvider()
        try data?.writeToPath(strongSelf.path, options: .atomic)
        strongSelf.completionHandler(strongSelf.path, nil)
      } catch {
        strongSelf.completionHandler(nil, error)
      }
    }
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    // The provider closure runs on `ioQueue` (see `handlePhotoCaptureResult`),
    // keeping the downscale off the capture callback thread.
    handlePhotoCaptureResult(error: error) { [maxPixelSize] in
      guard let data = photo.fileDataRepresentation() else { return nil }
      guard let maxPixelSize else { return data }
      return SavePhotoDelegate.downscaled(data, maxPixelSize: maxPixelSize)
    }
  }

  /// Re-encodes image data so its longest side is at most `maxPixelSize`,
  /// preserving the container type (JPEG/HEIF) and the image metadata
  /// (EXIF/TIFF/GPS, including the multi-frame fusion tags produced by the
  /// system photo pipeline). This mirrors `image_picker`'s native
  /// capture-then-scale behavior and takes ~tens of milliseconds for a 12 MP
  /// source.
  ///
  /// Fail-safe by construction: if the data can't be decoded or re-encoded for
  /// any reason, the original data is returned unchanged (a larger file, never
  /// a failed capture).
  static func downscaled(_ data: Data, maxPixelSize: Int) -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return data }

    let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
    guard max(width, height) > maxPixelSize else { return data }

    // `createThumbnailWithTransform: false` keeps pixels in sensor orientation;
    // the copied EXIF orientation tag continues to describe them correctly.
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: false,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard
      let scaled = CGImageSourceCreateThumbnailAtIndex(
        source, 0, thumbnailOptions as CFDictionary)
    else { return data }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
      return data
    }

    var outputProperties = properties
    outputProperties[kCGImagePropertyPixelWidth] = scaled.width
    outputProperties[kCGImagePropertyPixelHeight] = scaled.height
    if var exif = outputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
      exif[kCGImagePropertyExifPixelXDimension] = scaled.width
      exif[kCGImagePropertyExifPixelYDimension] = scaled.height
      outputProperties[kCGImagePropertyExifDictionary] = exif
    }
    // Comparable to the system camera's JPEG compression; keeps 2.8 MP files
    // in the same few-hundred-kB range as image_picker output.
    outputProperties[kCGImageDestinationLossyCompressionQuality] = 0.9

    CGImageDestinationAddImage(destination, scaled, outputProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return data }
    return output as Data
  }
}
