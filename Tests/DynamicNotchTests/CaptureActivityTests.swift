import Testing
@testable import DynamicNotch

@Test("capture activity stays inactive unless a positive device signal is present")
func captureActivityIsExplicit() {
    let inactive = CaptureActivity.inactive
    #expect(!inactive.isActive)

    let microphone = CaptureActivity(microphoneActive: true, cameraActive: false)
    #expect(microphone.isActive)
    #expect(!microphone.cameraActive)

    let camera = CaptureActivity(microphoneActive: false, cameraActive: true)
    #expect(camera.isActive)
    #expect(!camera.microphoneActive)
}
