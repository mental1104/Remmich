# 原生Live Photo正例夹具可行性

2026-11-24，独立分支 `codex/feature-native-live-photo-fixture-research`，基底 `f92b1e8413e78855556249d96a7b2eaa64e3bb2b`。本片仅研究公开API与配对格式，不修改App、主候选、测试选择或CI，不使用真实照片、Photos图库、设备权限或生产环境。

**结论：资源文件重建API及其完成/取消合同有充分主证；任意合成JPEG+MOV生成合法Live Photo、尤其Simulator接受它的合同仍未证。** 本次不新增一个未经Swift/PhotoKit验证、却会让统一CI硬失败的生成器，也不以空init、假PHLivePhoto或跳过断言填补正例。现有native非nil后的最终双fresh与实际播放正例仍是明确缺口。

## 已确认的API类型

| 用途 | 公开接口与注意事项 |
|---|---|
| 从本地文件重建 | `PHLivePhoto.request(withResourceFileURLs:placeholderImage:targetSize:contentMode:resultHandler:) -> PHLivePhotoRequestID`；iOS回调参数是`PHLivePhoto?`及`[AnyHashable: Any]`，不是AVPlayerItem。输入只含still和movie两个URL。Apple描述的是此前捕获并导出的同组Live资源，会在后台加载、验证并可能多次回调。[官方说明](https://developer.apple.com/documentation/photos/phlivephoto/request(withresourcefileurls:placeholderimage:targetsize:contentmode:resulthandler:)) |
| 工厂结果分类 | 使用`PHLivePhotoInfoIsDegradedKey`、`PHLivePhotoInfoErrorKey`和`PHLivePhotoInfoCancelledKey`；degraded不能作为成功终态，nil/error必须失败。[错误结果合同](https://developer.apple.com/documentation/photos/phlivephotoinfoerrorkey) |
| 取消 | 将真实`PHLivePhotoRequestID`交给`PHLivePhoto.cancelRequest(withRequestID:)`；不能交给PHImageManager.cancelImageRequest。[取消方法](https://developer.apple.com/documentation/photos/phlivephoto/cancelrequest(withrequestid:)) |
| native对象资源 | `PHAssetResource.assetResources(for: PHLivePhoto) -> [PHAssetResource]`，可在得到真正对象后核底层资源，而不先制造PHAsset或保存到图库。[对象资源接口](https://developer.apple.com/documentation/photos/phassetresource/assetresources(for:)-2fedw) |
| JPEG metadata容器 | ImageIO公开`kCGImagePropertyMakerAppleDictionary`，但所查官方页面未说明内部数字键17的Live content UUID写入合同。[ImageIO常量](https://developer.apple.com/documentation/imageio/kcgimagepropertymakerappledictionary) |
| MOV内容标识 | AVFoundation公开`AVMetadataIdentifier.quickTimeMetadataContentIdentifier`。存在此公开符号不能证明任意自造文件已满足整个Live格式。[标识符](https://developer.apple.com/documentation/avfoundation/avmetadataidentifier/quicktimemetadatacontentidentifier) |
| timed metadata写入 | `AVAssetWriterInputMetadataAdaptor`与AVTimedMetadataGroup是公开写轨机制；页面可用性包含到iOS27的版本变化，若后续实现须用实际target SDK确认声明/替代API，不能从API名称推断格式或编译通过。[公开adaptor](https://developer.apple.com/documentation/avfoundation/avassetwriterinputmetadataadaptor) |

这条资源工厂路径与产品中的`PHImageManager.requestLivePhoto(for:...)`不同：后者使用PHImageRequestID、PHImageResultIsDegradedKey及cancelImageRequest。不能为了工厂测试改坏产品adapter的结果键或取消函数。

## 配对格式主证及缺口

[Apple WWDC16 Session501，约18:14–19:08](https://developer.apple.com/videos/play/wwdc2016/501/)说明：JPEG和QuickTime movie共享一个UUID，JPEG放在Apple Maker Note，movie使用顶层QuickTime content identifier；movie还包含单样本timed metadata轨，对应still在时间线中的位置。演讲[官方PDF](https://devstreaming-cdn.apple.com/videos/wwdc/2016/501l32ujtbnw2ad06wy/501/501_advances_in_ios_photography.pdf?dl=1)第103页展示视频/音频/metadata及still时间的关系。这里只链接原始资料，不复制发布Apple幻灯片。

所查官方API页面、演讲文字及该PDF没有给出以下足以直接编码的完整规格；这是本轮检索范围内的证据缺口，不是宣称永远无法生成：

- ImageIO MakerApple字典内部数字键`17`的写入定义及UUID编码/保存保证。
- `com.apple.quicktime.still-image-time`的确切keySpace、数据类型、样本值、时长、轨描述，以及PhotoKit还要求哪些必需字段。
- 无音频/微小分辨率/极短合成视频是否足够；WWDC的典型参数不能被当作最小合法规范。
- 当前Xcode/iOS Simulator是否能在无图库/权限情况下验证并返回这种**从未捕获过的自造配对**。平台可用性声明不能替代该运行结果。

官方request说明还明确限制其可加载此前捕获Live Photo导出的同组文件。因此不能仅靠同UUID、AVAssetWriter完成或两文件可各自解码，就宣布PhotoKit native正例有效。NAS没有Swift/Xcode、Photos/AVFoundation执行环境，本轮没有生成或运行验证pair，未新增测试。

## 后续实验若获足够证据的验收标准

工厂应位于独立Tests文件，输出一个真正的PHLivePhoto和管理两文件生命周期的lease。只在自己的临时目录用公开ImageIO/AVFoundation生成合成内容；不导入图库、不上传，不依赖真实用户媒体。编码与验证用不同读取入口：ImageIO重新解码JPEG和标识，AVFoundation读取movie全局UUID、timed轨与实际可解码帧，核同一UUID和有效时间，再调用上面的真实Photos重建方法。

只接受非degraded、无error/cancel且非nil的最终PHLivePhoto；随后用PHAssetResource.assetResources(for:)核两成员的类型/身份，必要时固定network=false重新读取资源与源bytes/SHA256对照。成功前没有“positive”标签；原始nil/error诊断保留，失败硬失败，不能自动skip、mock成功或删掉断言。

请求ID安装前取消、实际在途取消、超时、late callback和文件lease释放需一次完成gate；测试失败也唤醒等待并回收文件。回调字典须在当次回调收束为明确值，不能跨Swift6 actor传裸Any字典。lease在native对象与host测试使用期间保留文件，最终显式回收。真正native对象可用于现Media helper最终双fresh以及PHLivePhotoView/协调器正例；它仍不能替代真实PHAsset/current源或设备权限验收。

下一项决定性证据应是实际macOS/iOS Simulator中这套生成物被公开Photos API接受的输出、runtime/SDK版本和资源身份核验；本轮没有启动任何新CI，不能把计划写成成功。
