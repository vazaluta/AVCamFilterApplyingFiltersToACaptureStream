/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The view controller for the AVCamFilter camera interface.
*/

import UIKit
import AVFoundation
import CoreVideo
import Photos
import MobileCoreServices

class CameraViewController: UIViewController, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate, AVCaptureDataOutputSynchronizerDelegate {
    
    // MARK: - Properties
    
    @IBOutlet weak private var photoButton: UIButton!
    
    @IBOutlet weak private var resumeButton: UIButton!
    
    @IBOutlet weak private var cameraUnavailableLabel: UILabel!
    
    @IBOutlet weak private var filterLabel: UILabel!
    
    @IBOutlet weak private var previewView: PreviewMetalView!
    
    @IBOutlet weak private var videoFilterButton: UIButton!
    
    private var videoFilterOn: Bool = false
    
    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    
    private var setupResult: SessionSetupResult = .success
    
    private let session = AVCaptureSession()
    
    private var isSessionRunning = false
    
    // Communicate with the session and other session objects on this queue.
    private let sessionQueue = DispatchQueue(label: "SessionQueue", attributes: [], autoreleaseFrequency: .workItem)
    
    private var videoInput: AVCaptureDeviceInput!
    
    private let dataOutputQueue = DispatchQueue(label: "VideoDataQueue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    private let videoDataOutput = AVCaptureVideoDataOutput()
    
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    
    private let photoOutput = AVCapturePhotoOutput()
    
    private let filterRenderers: [FilterRenderer] = [RosyCIRenderer()]
    
    private let photoRenderers: [FilterRenderer] = [RosyCIRenderer()]
    
    private var filterIndex: Int = 0
    
    private var videoFilter: FilterRenderer?
    
    private var photoFilter: FilterRenderer?
    
    private var renderingEnabled = true
    
    private let processingQueue = DispatchQueue(label: "photo processing queue", attributes: [], autoreleaseFrequency: .workItem)
    
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera,
                                                                                             .builtInWideAngleCamera],
                                                                               mediaType: .video,
                                                                               position: .unspecified)
    
    private var statusBarOrientation: UIInterfaceOrientation = .portrait
    
    // MARK: - View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Disable UI. The UI is enabled if and only if the session starts running.
        photoButton.isEnabled = false
        videoFilterOn = false
        videoFilterButton.setImage(#imageLiteral(resourceName: "ColorFilterOff"), for: .normal)
        
        // Check video authorization status, video access is required
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera
            break
            
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant video access
             Suspend the SessionQueue to delay session setup until the access request has completed
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access
            setupResult = .notAuthorized
        }
        
        /*
         Setup the capture session.
         In general it is not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Don't do this on the main queue, because AVCaptureSession.startRunning()
         is a blocking call, which can take a long time. Dispatch session setup
         to the sessionQueue so as not to block the main queue, which keeps the UI responsive.
         */
        sessionQueue.async {
            self.configureSession()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let interfaceOrientation = UIApplication.shared.statusBarOrientation
        statusBarOrientation = interfaceOrientation
        
        let initialThermalState = ProcessInfo.processInfo.thermalState
        if initialThermalState == .serious || initialThermalState == .critical {
            showThermalState(state: initialThermalState)
        }
        
        sessionQueue.async {
            switch self.setupResult {
            case .success:
                self.addObservers()
                
                if let photoOrientation = AVCaptureVideoOrientation(interfaceOrientation: interfaceOrientation) {
                    if let unwrappedPhotoOutputConnection = self.photoOutput.connection(with: .video) {
                        unwrappedPhotoOutputConnection.videoOrientation = photoOrientation
                    }
                }
                
                if let unwrappedVideoDataOutputConnection = self.videoDataOutput.connection(with: .video) {
                    let videoDevicePosition = self.videoInput.device.position
                    let rotation = PreviewMetalView.Rotation(with: interfaceOrientation,
                                                             videoOrientation: unwrappedVideoDataOutputConnection.videoOrientation,
                                                             cameraPosition: videoDevicePosition)
                    self.previewView.mirroring = (videoDevicePosition == .front)
                    if let rotation = rotation {
                        self.previewView.rotation = rotation
                    }
                }
                self.dataOutputQueue.async {
                    self.renderingEnabled = true
                }
                
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                
                
            case .notAuthorized:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("AVCamFilter doesn't have permission to use the camera, please change privacy settings",
                                                    comment: "Alert message when the user has denied access to the camera")
                    let actions = [
                        UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                      style: .cancel,
                                      handler: nil),
                        UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                      style: .`default`,
                                      handler: { _ in
                                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                  options: [:],
                                                                  completionHandler: nil)
                        })
                    ]
                    
                    self.alert(title: "AVCamFilter", message: message, actions: actions)
                }
                
            case .configurationFailed:
                DispatchQueue.main.async {
                    
                    let message = NSLocalizedString("Unable to capture media",
                                                    comment: "Alert message when something goes wrong during capture session configuration")
                    
                    self.alert(title: "AVCamFilter",
                               message: message,
                               actions: [UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                       style: .cancel,
                                                       handler: nil)])
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        dataOutputQueue.async {
            self.renderingEnabled = false
        }
        sessionQueue.async {
            if self.setupResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
                self.removeObservers()
            }
        }
        
        super.viewWillDisappear(animated)
    }
    
    @objc
    func didEnterBackground(notification: NSNotification) {
        // Free up resources.
        dataOutputQueue.async {
            self.renderingEnabled = false
            if let videoFilter = self.videoFilter {
                videoFilter.reset()
            }
            self.previewView.pixelBuffer = nil
            self.previewView.flushTextureCache()
        }
        processingQueue.async {
            if let photoFilter = self.photoFilter {
                photoFilter.reset()
            }
        }
    }
    
    @objc
    func willEnterForground(notification: NSNotification) {
        dataOutputQueue.async {
            self.renderingEnabled = true
        }
    }
    
    // Use this opportunity to take corrective action to help cool the system down.
    @objc
    func thermalStateChanged(notification: NSNotification) {
        if let processInfo = notification.object as? ProcessInfo {
            showThermalState(state: processInfo.thermalState)
        }
    }
    
    func showThermalState(state: ProcessInfo.ThermalState) {
        DispatchQueue.main.async {
            var thermalStateString = "UNKNOWN"
            if state == .nominal {
                thermalStateString = "NOMINAL"
            } else if state == .fair {
                thermalStateString = "FAIR"
            } else if state == .serious {
                thermalStateString = "SERIOUS"
            } else if state == .critical {
                thermalStateString = "CRITICAL"
            }
            
            let message = NSLocalizedString("Thermal state: \(thermalStateString)", comment: "Alert message when thermal state has changed")
            let actions = [
                UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                              style: .cancel,
                              handler: nil)]
            
            self.alert(title: "AVCamFilter", message: message, actions: actions)
        }
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        coordinator.animate( alongsideTransition: { _ in
                let interfaceOrientation = UIApplication.shared.statusBarOrientation
                self.statusBarOrientation = interfaceOrientation
                self.sessionQueue.async {
                    /*
                     The photo orientation is based on the interface orientation. You could also set the orientation of the photo connection based
                     on the device orientation by observing UIDeviceOrientationDidChangeNotification.
                     */
                    if let photoOrientation = AVCaptureVideoOrientation(interfaceOrientation: interfaceOrientation) {
                        if let unwrappedPhotoOutputConnection = self.photoOutput.connection(with: .video) {
                            unwrappedPhotoOutputConnection.videoOrientation = photoOrientation
                        }
                    }
                    
                    if let unwrappedVideoDataOutputConnection = self.videoDataOutput.connection(with: .video) {
                        
                        if let rotation = PreviewMetalView.Rotation(with: interfaceOrientation,
                                                                    videoOrientation: unwrappedVideoDataOutputConnection.videoOrientation,
                                                                    cameraPosition: self.videoInput.device.position) {
                            self.previewView.rotation = rotation
                        }
                    }
                }
        }, completion: nil)
    }
    
    // MARK: - KVO and Notifications
    
    private var sessionRunningContext = 0
    
    private func addObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(willEnterForground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(thermalStateChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError),
                                               name: NSNotification.Name.AVCaptureSessionRuntimeError,
                                               object: session)
        
        session.addObserver(self, forKeyPath: "running", options: NSKeyValueObservingOptions.new, context: &sessionRunningContext)
        
        // A session can run only when the app is full screen. It will be interrupted in a multi-app layout.
        // Add observers to handle these session interruptions and inform the user.
        // See AVCaptureSessionWasInterruptedNotification for other interruption reasons.
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted),
                                               name: NSNotification.Name.AVCaptureSessionWasInterrupted,
                                               object: session)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded),
                                               name: NSNotification.Name.AVCaptureSessionInterruptionEnded,
                                               object: session)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(subjectAreaDidChange),
                                               name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange,
                                               object: videoInput.device)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        session.removeObserver(self, forKeyPath: "running", context: &sessionRunningContext)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context == &sessionRunningContext {
            let newValue = change?[.newKey] as AnyObject?
            guard let isSessionRunning = newValue?.boolValue else { return }
            DispatchQueue.main.async {
//                self.cameraButton.isEnabled = (isSessionRunning && self.videoDeviceDiscoverySession.devices.count > 1)
                self.photoButton.isEnabled = isSessionRunning
                self.videoFilterButton.isEnabled = isSessionRunning
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    // MARK: - Session Management
    
    #warning("セッションの設定する")
    // Call this on the SessionQueue
    private func configureSession() {
        if setupResult != .success {
            return
        }
        
        let defaultVideoDevice: AVCaptureDevice? = videoDeviceDiscoverySession.devices.first
        
        guard let videoDevice = defaultVideoDevice else {
            print("Could not find any video device")
            setupResult = .configurationFailed
            return
        }
        
        do {
            videoInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            print("Could not create video device input: \(error)")
            setupResult = .configurationFailed
            return
        }
        
        session.beginConfiguration()
        
        session.sessionPreset = AVCaptureSession.Preset.photo
        
        // Add a video input.
        guard session.canAddInput(videoInput) else {
            print("Could not add video device input to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        session.addInput(videoInput)
        
        // Add a video data output
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        } else {
            print("Could not add video data output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        // Add photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            
            photoOutput.isHighResolutionCaptureEnabled = true
            
        } else {
            print("Could not add photo output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        
    }
    
    @objc
    func sessionWasInterrupted(notification: NSNotification) {
        // In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
            let reasonIntegerValue = userInfoValue.integerValue,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")
            
            if reason == .videoDeviceInUseByAnotherClient {
                // Simply fade-in a button to enable the user to try to resume the session running.
                resumeButton.isHidden = false
                resumeButton.alpha = 0.0
                UIView.animate(withDuration: 0.25) {
                    self.resumeButton.alpha = 1.0
                }
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                // Simply fade-in a label to inform the user that the camera is unavailable.
                cameraUnavailableLabel.isHidden = false
                cameraUnavailableLabel.alpha = 0.0
                UIView.animate(withDuration: 0.25) {
                    self.cameraUnavailableLabel.alpha = 1.0
                }
            }
        }
    }
    
    @objc
    func sessionInterruptionEnded(notification: NSNotification) {
        if !resumeButton.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.resumeButton.alpha = 0
            }, completion: { _ in
                self.resumeButton.isHidden = true
            }
            )
        }
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.cameraUnavailableLabel.alpha = 0
            }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            }
            )
        }
    }
    
    @objc
    func sessionRuntimeError(notification: NSNotification) {
        guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        
        let error = AVError(_nsError: errorValue)
        print("Capture session runtime error: \(error)")
        
        /*
         Automatically try to restart the session running if media services were
         reset and the last start running succeeded. Otherwise, enable the user
         to try to resume the session running.
         */
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                } else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            resumeButton.isHidden = false
        }
    }
    
    @IBAction private func resumeInterruptedSession(_ sender: UIButton) {
        sessionQueue.async {
            /*
             The session might fail to start running. A failure to start the session running will be communicated via
             a session runtime error notification. To avoid repeatedly failing to start the session
             running, we only try to restart the session running in the session runtime error handler
             if we aren't trying to resume the session running.
             */
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            if !self.session.isRunning {
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let actions = [
                        UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                      style: .cancel,
                                      handler: nil)]
                    self.alert(title: "AVCamFilter", message: message, actions: actions)
                }
            } else {
                DispatchQueue.main.async {
                    self.resumeButton.isHidden = true
                }
            }
        }
    }
    
    // MARK: - IBAction Functions
    @objc
    func subjectAreaDidChange(notification: NSNotification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
    }
    #warning("フィルターのオンオフ")
    @IBAction private func toggleFiltering() {
        
        videoFilterOn = !videoFilterOn
        let filteringEnabled = videoFilterOn
        
        let stateImage = UIImage(named: filteringEnabled ? "ColorFilterOn" : "ColorFilterOff")
        self.videoFilterButton.setImage(stateImage, for: .normal)
        
        let index = filterIndex
        
        if filteringEnabled {
            let filterDescription = filterRenderers[index].description
            updateFilterLabel(description: filterDescription)
        }
        
        // Enable/disable the video filter.
        dataOutputQueue.async {
            if filteringEnabled {
                self.videoFilter = self.filterRenderers[index]
            } else {
                if let filter = self.videoFilter {
                    filter.reset()
                }
                self.videoFilter = nil
            }
        }
        
        // Enable/disable the photo filter.
        processingQueue.async {
            if filteringEnabled {
                self.photoFilter = self.photoRenderers[index]
            } else {
                if let filter = self.photoFilter {
                    filter.reset()
                }
                self.photoFilter = nil
            }
        }
    }
    #warning("写真を撮る")
    @IBAction private func capturePhoto(_ photoButton: UIButton) {
//        let depthEnabled = depthVisualizationOn
        
        sessionQueue.async {
            let photoSettings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
            photoSettings.isDepthDataDeliveryEnabled = false
            
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
    
    // MARK: - UI Utility Functions
    func updateFilterLabel(description: String) {
        filterLabel.text = description
        filterLabel.alpha = 0.0
        filterLabel.isHidden = false
        
        UIView.animate(withDuration: 0.25, animations: {
            self.filterLabel.alpha = 1.0
        }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.0, options: [], animations: {
                self.filterLabel.alpha = 0.0
            }, completion: { _ in })
        }
    }
    
    // MARK: - Video Data Output Delegate
    #warning("ビデオ出力処理")
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processVideo(sampleBuffer: sampleBuffer)
    }
    
    func processVideo(sampleBuffer: CMSampleBuffer) {
        if !renderingEnabled {
            return
        }
        
        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
        }
        
        var finalVideoPixelBuffer = videoPixelBuffer
        if let filter = videoFilter {
            if !filter.isPrepared {
                /*
                 outputRetainedBufferCountHint is the number of pixel buffers the renderer retains. This value informs the renderer
                 how to size its buffer pool and how many pixel buffers to preallocate. Allow 3 frames of latency to cover the dispatch_async call.
                 */
                filter.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
            }
            
            // Send the pixel buffer through the filter
            guard let filteredBuffer = filter.render(pixelBuffer: finalVideoPixelBuffer) else {
                print("Unable to filter video buffer")
                return
            }
            
            finalVideoPixelBuffer = filteredBuffer
        }
        
        previewView.pixelBuffer = finalVideoPixelBuffer
    }
    
    // MARK: - Depth Data Output Delegate
    
    // MARK: - Video + Depth Output Synchronizer Delegate
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        if let syncedVideoData: AVCaptureSynchronizedSampleBufferData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData {
            if !syncedVideoData.sampleBufferWasDropped {
                let videoSampleBuffer = syncedVideoData.sampleBuffer
                processVideo(sampleBuffer: videoSampleBuffer)
            }
        }
    }
    #warning("写真の出力")
    // MARK: - Photo Output Delegate
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        flashScreen()
        AudioServicesDisposeSystemSoundID(1108)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let photoPixelBuffer = photo.pixelBuffer else {
            print("Error occurred while capturing photo: Missing pixel buffer (\(String(describing: error)))")
            return
        }
        
        var photoFormatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: photoPixelBuffer,
                                                     formatDescriptionOut: &photoFormatDescription)
        
        processingQueue.async {
            var finalPixelBuffer = photoPixelBuffer
            #warning("フィルターをかける")
            if let filter = self.photoFilter {
                if !filter.isPrepared {
                    if let unwrappedPhotoFormatDescription = photoFormatDescription {
                        filter.prepare(with: unwrappedPhotoFormatDescription, outputRetainedBufferCountHint: 2)
                    }
                }
                
                guard let filteredPixelBuffer = filter.render(pixelBuffer: finalPixelBuffer) else {
                    print("Unable to filter photo buffer")
                    return
                }
                finalPixelBuffer = filteredPixelBuffer
            }
            
            let metadataAttachments: CFDictionary = photo.metadata as CFDictionary
            guard let jpegData = CameraViewController.jpegData(withPixelBuffer: finalPixelBuffer, attachments: metadataAttachments) else {
                print("Unable to create JPEG photo")
                return
            }
            
            // Save JPEG to photo library
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized {
                    PHPhotoLibrary.shared().performChanges({
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .photo, data: jpegData, options: nil)
                    }, completionHandler: { _, error in
                        if let error = error {
                            print("Error occurred while saving photo to photo library: \(error)")
                        }
                    })
                }
            }
        }
    }
    
    // MARK: - Utilities
    
    private func focus(with focusMode: AVCaptureDevice.FocusMode, exposureMode: AVCaptureDevice.ExposureMode, at devicePoint: CGPoint, monitorSubjectAreaChange: Bool) {
        
        sessionQueue.async {
            let videoDevice = self.videoInput.device
            
            do {
                try videoDevice.lockForConfiguration()
                if videoDevice.isFocusPointOfInterestSupported && videoDevice.isFocusModeSupported(focusMode) {
                    videoDevice.focusPointOfInterest = devicePoint
                    videoDevice.focusMode = focusMode
                }
                
                if videoDevice.isExposurePointOfInterestSupported && videoDevice.isExposureModeSupported(exposureMode) {
                    videoDevice.exposurePointOfInterest = devicePoint
                    videoDevice.exposureMode = exposureMode
                }
                
                videoDevice.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                videoDevice.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }
    
    func alert(title: String, message: String, actions: [UIAlertAction]) {
        let alertController = UIAlertController(title: title,
                                                message: message,
                                                preferredStyle: .alert)
        
        actions.forEach {
            alertController.addAction($0)
        }
        
        self.present(alertController, animated: true, completion: nil)
    }
    
    // Flash the screen to signal that AVCamFilter took a photo.
    func flashScreen() {
        let flashView = UIView(frame: self.previewView.frame)
        self.view.addSubview(flashView)
        flashView.backgroundColor = .black
        flashView.layer.opacity = 1
        UIView.animate(withDuration: 0.25, animations: {
            flashView.layer.opacity = 0
        }, completion: { _ in
            flashView.removeFromSuperview()
        })
    }
    
    private class func jpegData(withPixelBuffer pixelBuffer: CVPixelBuffer, attachments: CFDictionary?) -> Data? {
        let ciContext = CIContext()
        let renderedCIImage = CIImage(cvImageBuffer: pixelBuffer)
        guard let renderedCGImage = ciContext.createCGImage(renderedCIImage, from: renderedCIImage.extent) else {
            print("Failed to create CGImage")
            return nil
        }
        
        guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0) else {
            print("Create CFData error!")
            return nil
        }
        
        guard let cgImageDestination = CGImageDestinationCreateWithData(data, kUTTypeJPEG, 1, nil) else {
            print("Create CGImageDestination error!")
            return nil
        }
        
        CGImageDestinationAddImage(cgImageDestination, renderedCGImage, attachments)
        if CGImageDestinationFinalize(cgImageDestination) {
            return data as Data
        }
        print("Finalizing CGImageDestination error!")
        return nil
    }
}

extension AVCaptureVideoOrientation {
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}

extension PreviewMetalView.Rotation {
    init?(with interfaceOrientation: UIInterfaceOrientation, videoOrientation: AVCaptureVideoOrientation, cameraPosition: AVCaptureDevice.Position) {
        /*
         Calculate the rotation between the videoOrientation and the interfaceOrientation.
         The direction of the rotation depends upon the camera position.
         */
        switch videoOrientation {
        case .portrait:
            switch interfaceOrientation {
            case .landscapeRight:
                if cameraPosition == .front {
                    self = .rotate90Degrees
                } else {
                    self = .rotate270Degrees
                }
                
            case .landscapeLeft:
                if cameraPosition == .front {
                    self = .rotate270Degrees
                } else {
                    self = .rotate90Degrees
                }
                
            case .portrait:
                self = .rotate0Degrees
                
            case .portraitUpsideDown:
                self = .rotate180Degrees
                
            default: return nil
            }
        case .portraitUpsideDown:
            switch interfaceOrientation {
            case .landscapeRight:
                if cameraPosition == .front {
                    self = .rotate270Degrees
                } else {
                    self = .rotate90Degrees
                }
                
            case .landscapeLeft:
                if cameraPosition == .front {
                    self = .rotate90Degrees
                } else {
                    self = .rotate270Degrees
                }
                
            case .portrait:
                self = .rotate180Degrees
                
            case .portraitUpsideDown:
                self = .rotate0Degrees
                
            default: return nil
            }
            
        case .landscapeRight:
            switch interfaceOrientation {
            case .landscapeRight:
                self = .rotate0Degrees
                
            case .landscapeLeft:
                self = .rotate180Degrees
                
            case .portrait:
                if cameraPosition == .front {
                    self = .rotate270Degrees
                } else {
                    self = .rotate90Degrees
                }
                
            case .portraitUpsideDown:
                if cameraPosition == .front {
                    self = .rotate90Degrees
                } else {
                    self = .rotate270Degrees
                }
                
            default: return nil
            }
            
        case .landscapeLeft:
            switch interfaceOrientation {
            case .landscapeLeft:
                self = .rotate0Degrees
                
            case .landscapeRight:
                self = .rotate180Degrees
                
            case .portrait:
                if cameraPosition == .front {
                    self = .rotate90Degrees
                } else {
                    self = .rotate270Degrees
                }
                
            case .portraitUpsideDown:
                if cameraPosition == .front {
                    self = .rotate270Degrees
                } else {
                    self = .rotate90Degrees
                }
                
            default: return nil
            }
        @unknown default:
            fatalError("Unknown orientation.")
        }
    }
}
