# 原生Live Photo正例夹具可行性

2026-11-24，独立分支 `codex/feature-native-live-photo-fixture-research`，基底 `f92b1e8413e78855556249d96a7b2eaa64e3bb2b`。在初次Apple资料研究 `0fa7104` 后，补入ExifTool所有者维护的格式实现主证及独立Tests实验工厂；不修改App、主候选、测试选择或CI，不使用真实照片、Photos图库、设备权限或生产环境。

**结论：已有足够主证编写可运行实验，尚无Swift/Simulator执行结果。** 新增 `SyntheticLivePhotoFixture.make() async throws` 实际编码JPEG/MOV、独立回读、调用公开PhotoKit重建；只有非degraded、无error/cancel且非nil的真正对象才返回。一个两分钟上限的真实正例测试将失败视为失败，不skip、不用空init或mock成功。下一统一native CI才会证明当前Simulator是否接受；现有Media最终双fresh/真实播放测试尚未接入这个工厂。

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

## 配对格式主证及实验推断

[Apple WWDC16 Session501，约18:14–19:08](https://developer.apple.com/videos/play/wwdc2016/501/)说明：JPEG和QuickTime movie共享一个UUID，JPEG放在Apple Maker Note，movie使用顶层QuickTime content identifier；movie还包含单样本timed metadata轨，对应still在时间线中的位置。演讲[官方PDF](https://devstreaming-cdn.apple.com/videos/wwdc/2016/501l32ujtbnw2ad06wy/501/501_advances_in_ios_photography.pdf?dl=1)第103页展示视频/音频/metadata及still时间的关系。这里只链接原始资料，不复制发布Apple幻灯片。

ExifTool作者维护的[Apple.pm](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Apple.pm#L109-L115)把MakerNote `0x0011`定义为string型ContentIdentifier，十进制对应17；[作者生成的Apple tag表](https://github.com/exiftool/exiftool/blob/master/html/TagNames/Apple.html)给出同一映射。结合Apple公开MakerApple字典，本实验通过ImageIO写入 `["17": UUID]`，随后从真正落盘JPEG重新读取。**ImageIO内部键17映射及PhotoKit接受性仍是待运行的推断，ExifTool定义不是Apple写入保证。**

[QuickTime.pm](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/QuickTime.pm#L6803)记录顶层content.identifier；同文件[still-image-time段](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/QuickTime.pm#L6848-L6855)记录mdta标识、dtyp65/int8s、样本值恒为`-1`，实际still时刻取样本时间。作者的[QuickTimeStream.pl](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/QuickTimeStream.pl)也把65映射为int8s。这支持本实验写 `mdta/com.apple.quicktime.still-image-time`、`kCMMetadataBaseDataType_SInt8`和`NSNumber(Int8(-1))`，并通过AVAssetReader回读类型、值、1.5秒时间。ExifTool该timed字段标记不可写，本实验**不声称由ExifTool生成了该轨**；写入机制使用公开AVAssetWriter/CMMetadata API。

合成参数为320×240、H264、30fps、3秒，90个有效BGRA几何图案帧；44.1kHz/16bit mono全零PCM音轨；同UUID的JPEG画面对应第45帧，marker持续1/30秒。JPEG renderer明确scale=1以免Simulator Retina scale改变像素。选择这些参数为了低成本完整实验，**不是声明最低合法规格或复制相机输出**。WWDC典型参数不能被当作最小规范，任意合成配对仍不在Apple导出资源保证内。

## 已实现的执行路径与收口

`RemmichTests/SyntheticLivePhotoFixture.swift`只在唯一 `NativeLiveFixture-UUID` temp目录生成文件。工厂返回MainActor lease，其 `native: PHLivePhoto`、`stillURL/motionURL`、`identifier`、`pixels`、`stillDigest/motionDigest`（真实输入SHA1/base64/字节数）、SHA256/metadata收据可供后续host正例复用；`close()`只删除该目录且可重复关闭。实际native/host使用完成前必须保留lease。

编码与验证使用不同读取入口：ImageIO重新解码JPEG尺寸和Maker UUID；AVURLAsset异步加载movie全局UUID/时长/轨；AVAssetImageGenerator公开async [image(at:)](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:))实际解码1.5秒帧并核actualTime；AVAssetReaderOutputMetadataAdaptor读取唯一timed样本，公开async [load(.numberValue)](https://developer.apple.com/documentation/avfoundation/avpartialasyncproperty/numbervalue)核其值为-1，另核类型/时间。文件校验通过后实际调用Photos request；仅真正native成功后核 `PHAssetResource.assetResources(for:)` 包含一个photo/fullSizePhoto和一个pairedVideo/fullSizePairedVideo。**不要求PHAssetResourceManager能读取未入库重建对象**；源文件摘要独立核对，不伪称已证明native内部字节或真实PHAsset current来源。

writer readiness共享30秒预算，finish和Photos request各有10秒唤醒门；Task取消、超时、请求ID尚未安装和迟到回调复用真实Sendable `PhotoResourceRead`。callback字典在当前回调内消费，只有Sendable对象/固定诊断进入gate；未使用`@preconcurrency`或`@unchecked Sendable`绕检查。Photos native factory使用自己的PHLivePhotoInfo键与cancelRequest，产品ImageManager adapter未改。失败保留本例文件、`failure.json`（stage、系统错误domain/code、nativeReturned与fixtureSuccess=false）及temp路径，硬失败；成功测试打印脱敏receipt并显式close。

`SyntheticLivePhotoFixtureTests.publicFileRequestBuildsGenuineNativePhoto`实际调用工厂，独立重读两文件算SHA1/base64/字节数和SHA256，核UUID/marker/像素/真实native.size/资源类型与落盘收据、close及重复close。没有fake或可跳过分支。失败仍可能揭示ImageIO写入不受支持、编码/轨参数不被PhotoKit接受、SDK编译类型变化或Simulator实现限制，需在统一CI如实修复，不能删断言改成假成功。

NAS实际只完成两新Swift文件SwiftFormat0.64.5格式/lint、差异与静态路径检查，无Swift/Xcode、Photos/AVFoundation运行环境。**编译、该一个真正native正例、合成文件解码/PhotoKit接受性、host最终双fresh/播放和真机均未验证。** 本片没有启动CI、不修改workflow或主候选、不使用私人媒体/生产/权限/网络。回退只撤销两Tests文件和本片文档；无数据迁移或用户资源修改。
