# PAGE-IDENTITY-1 原页内容对照

日期 2026-10-17。已只读实际原件 30 页图像和指定 ZIP（70 个成员全部有界解压/CRC/hash），用现有 `MineruPdfNormalizer` 还原稳定 `node-N` 及 caption 子节点。没有设备/snapshot 导出权限，本轮不是已入库数据库读取；导入必须再核实际 snapshot/hash 和节点集合摘要。未使用 top5、查询结果或向量挑来源，冻结 V1 不改。

## 逐页审查

每行都是独立原页内容加结构/顺序核对，不是服务 idx+1 推断；恰好一致不构成一般规则。完整受审 node ID 列表及对应文本集合 SHA256 见 `entry/src/main/resources/rawfile/pdf-page-review-v1.json`。摘要输入为有序 `JSON.stringify([[node.id,node.pageIndex0,node.text],...])`，精确原串，不做 OCR 归一化。页码只给列明完整节点；cross 单列。

| 原物理页 | provider idx | 独立原件特异内容 / 实际解析对应结构 |
|---|---|---|
|1|0|§2.1 经验误差与过拟合，node-3/4/5；NP 段跨页 node-6|
|2|1|图2.1叶片类比 caption node-10，§2.2 node-13，测试集互斥 node-15|
|3|2|§2.2.1 node-22，700/300 node-24，分层及重复划分 node-25/26|
|4|3|§2.2.2 node-34，图2.2 node-36-caption，留一法引入 node-39|
|5|4|§2.2.3 node-49，式2.1 node-52，36.8%/OOB node-53|
|6|5|§2.2.4 node-61，5^3=125 node-63，validation node-65，§2.3 node-66|
|7|6|MSE node-73/74/76，§2.3.1 node-78，式2.4–6 node-80/82/84|
|8|7|§2.3.2 node-88，表2.1 node-93，式2.7/8/9 node-87/95/96|
|9|8|图2.3 node-105-caption，P-R及BEP node-106/107|
|10|9|F1/Fbeta node-111/116，macro/micro式2.12–15 node-122–126|
|11|10|式2.16/17 node-129/130，§2.3.3 node-131，TPR/FPR node-136/137|
|12|11|图2.4(a)/(b) node-141/142-caption，有限样本ROC node-143，AUC node-144/145|
|13|12|式2.20–22 node-148/150/152，§2.3.4 node-153，表2.2 node-157|
|14|13|式2.23–25 node-161/165/168，cost curve node-164/169|
|15|14|图2.5 node-172-caption，§2.4/2.4.1 node-173/177；node-178跨页|
|16|15|式2.26/27 node-183/189，图2.6 node-186-caption|
|17|16|式2.28–30 node-196/197/199，图2.7 node-201-caption；node-202跨页|
|18|17|表2.3含2.262 node-207，§2.4.2 node-209，式2.31 node-212|
|19|18|§2.4.3 node-221，表2.4 node-223，式2.32/33 node-219/225|
|20|19|§2.4.4 node-231，表2.5含1/2.125/2.875 node-234，式2.34/35|
|21|20|表2.6/2.7 node-244/250，CD式2.36 node-247|
|22|21|CD1.657 node-253，图2.8 node-255-caption，§2.5 node-256|
|23|22|式2.37–42 node-263–276，noise/bias/variance；node-278跨页|
|24|23|图2.9 node-284-caption，§2.6 node-285，训练程度/过拟合 node-283|
|25|24|阅读材料限MSE回归 node-293；Hanley/Hand/Fawcett node-290|
|26|25|习题2.1–2.10 node-297–309，式2.43/44 node-306/307|
|27|26|参考文献标题 node-312，Bradley至Hanley/McNeil node-313–325|
|28|27|Kohavi至Zhou/Liu参考文献 node-328–334|
|29|28|休息一会儿 node-337/338，1899/Gosset node-339，Student node-341，UCL node-342|
|30|29|原件目视无正文、有扫描痕迹；无解析块，不生成证据，不推断空页规则|

## 5 个跨页合并节点

16 个 flagged span 按内容定位到以下 5 个节点。逐段核原页断句，不靠 bbox 或 nearest 匹配。UTF-16 半开区间及逐片 SHA256 已冻结在清单；`lines_deleted` 为空的节点不另授予。

| node | 前片原页/范围 | 后片原页/范围 | 原件真实断点 |
|---|---|---|---|
|node-6|1 / [0,292)|2 / [292,378)|多项式时间内 / 运行完成|
|node-97|8 / [0,102)|9 / [102,207)|所有好瓜也 / 必然都被选上了|
|node-178|15 / [0,137)|16 / [137,178)|接近的可能性应比 / 较大|
|node-202|17 / [0,277)|18 / [277,473)|位于临界值范围 / [t_-α/2,t_α/2] 内|
|node-278|23 / [0,36)|24 / [36,284)|期望预测与 / 真实结果的偏离程度|

空 node-11/100/181/205/281（provider1/8/15/17/23）不生成证据。页眉、页码、无文字图片不在受审文字清单内，不因页锚点批量转绿。所有列明普通节点仅证明页身份，不证明区域/文字OCR正确率/答案质量。多源块必须逐节点覆盖；仅片段有证据则Partial，互斥页证据则Conflict。注册没有生产执行，本阶段只交付可导入明确受审数据。

## 实际离线回归结论

最终host278/278中实际复算：受审292文字nodes（287普通＋5跨页），原chunker343块全部有受审来源，按每块sourceStart/sourceEnd投影后5块跨页；空5node和原页30保持未绑定、无冲突。完整normalizer节点集合SHA与冻结snapshot SHA `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281`一致。该结论来自指定原件/ZIP与同adapter，不是本轮生产库读回。

清单SHA256 `d99055bb5e8005a73d2c085870cc4f5a405ef8ee59768d3354e8844e72faee39`。导入仅显式“登记已审原页”，完整身份＋清单hash＋actual snapshot nodeSet/fragment hash匹配才append元数据；通用registry/service支持其它单独受审数据，不给其它PDF一键套用本样本。证据`.cache/test-logs/2026-10-17-result-pages-host-final-08-9f5992c/host.log`，复现命令见result-pages-implementation.md。
