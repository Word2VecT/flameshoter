// SPDX-License-Identifier: GPL-3.0-or-later
import MetalPerformanceShaders
import Testing

extension Trait where Self == ConditionTrait {
  static var requiresVisionAccelerator: Self {
    .enabled(
      if: MTLCreateSystemDefaultDevice().map { MPSSupportsMTLDevice($0) } ?? false,
      "Apple Vision integration tests require a Metal Performance Shaders device.")
  }
}
