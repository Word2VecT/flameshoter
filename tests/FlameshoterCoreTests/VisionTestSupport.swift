// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing

extension Trait where Self == ConditionTrait {
  static var requiresOnDeviceVision: Self {
    // The GitHub-hosted virtual Mac advertises Metal and MPS, but its system OCR
    // returns empty text or VNError. Keep running these integrations on a real Mac.
    var guest: Int32 = 0
    var size = MemoryLayout.size(ofValue: guest)
    let isGuest = sysctlbyname("kern.hv_vmm_present", &guest, &size, nil, 0) == 0 && guest != 0
    let isHosted = ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted"
    return .enabled(if: !(isGuest && isHosted), "System OCR integration is verified on a physical Mac.")
  }
}
