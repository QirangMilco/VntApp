import 'legal_page.dart';

/// 隐私政策内容
class PrivacyPolicyContent {
  static const String title = '隐私政策';
  static const String subtitle = 'Privacy Policy';
  static const String lastUpdated = '2026 年 5 月 16 日';

  static const List<LegalSection> sections = [
    // 引言
    LegalSection(
      paragraphs: [
        LegalParagraph('感谢你使用 VNT App（以下简称"本应用"）。本应用由开发者维护（以下简称"我们"）。我们深知隐私对你的重要性，因此制定了本隐私政策，说明我们如何收集、使用、存储和保护你的信息。'),
        LegalParagraph('请在使用本应用前仔细阅读本隐私政策。使用本应用即表示你同意本隐私政策所述的处理方式。'),
      ],
    ),

    // 1. 收集的信息
    LegalSection(
      title: '1. 我们收集的信息',
      subSections: [
        LegalSubSection(
          title: '1.1 你主动提供的信息',
          items: [
            LegalListItem('网络配置信息：服务器地址、端口号、组网令牌/密码、设备名称等你手动输入的组网配置信息。这些信息仅存储在你的设备本地，用于建立虚拟组网连接。'),
            LegalListItem('应用偏好设置：主题颜色、自动连接开关、默认配置等你在应用内设定的偏好。'),
          ],
        ),
        LegalSubSection(
          title: '1.2 自动收集的信息',
          items: [
            LegalListItem('设备信息：设备型号、操作系统版本（通过 device_info_plus 获取），用于确保兼容性和提供技术支持。'),
            LegalListItem('日志信息：应用运行过程中产生的调试日志，包括连接状态、错误信息、网络延迟数据等。iOS 端日志仅保存在本地控制台，不会自动上传。'),
            LegalListItem('网络流量元数据：作为 VPN/组网工具，本应用会处理经过虚拟网卡的网络数据包。我们不会记录、存储或分析你的具体通信内容。'),
          ],
        ),
      ],
    ),

    // 2. 信息的使用
    LegalSection(
      title: '2. 信息的使用',
      paragraphs: [
        LegalParagraph('我们收集的信息仅用于以下目的：'),
      ],
      items: [
        LegalListItem('建立、维护和优化虚拟组网连接'),
        LegalListItem('诊断和修复应用运行中的问题'),
        LegalListItem('改善用户体验和应用性能'),
      ],
    ),
    LegalSection(
      paragraphs: [
        LegalParagraph('我们不会将你的信息用于广告投放、用户画像或任何商业销售目的。'),
      ],
    ),

    // 3. 存储和保护
    LegalSection(
      title: '3. 信息的存储和保护',
      items: [
        LegalListItem('本地存储：所有配置信息和偏好设置均存储在你的设备本地（通过 SharedPreferences 和本地文件系统）。'),
        LegalListItem('数据安全：组网通信采用端到端加密传输，保护你的数据在传输过程中的安全。'),
        LegalListItem('日志保留：日志文件仅在本地保留，你可以随时在应用设置中手动清理或删除。'),
      ],
    ),

    // 4. 共享与披露
    LegalSection(
      title: '4. 信息的共享与披露',
      paragraphs: [
        LegalParagraph('我们不会向任何第三方出售、交易或转让你的个人信息。以下情况除外：'),
      ],
      items: [
        LegalListItem('获得你的明确同意'),
        LegalListItem('法律法规要求'),
        LegalListItem('保护我们的合法权益（如应对法律诉讼）'),
      ],
    ),

    // 5. 网络扩展说明
    LegalSection(
      title: '5. 网络扩展（Network Extension）说明',
      paragraphs: [
        LegalParagraph('本应用在 iOS 上使用了 Network Extension（Packet Tunnel Provider）来建立虚拟专用网络连接。这意味着：'),
      ],
      items: [
        LegalListItem('应用可以捕获和路由经过虚拟网卡的网络流量'),
        LegalListItem('我们承诺不会监控、记录或篡改你的通信内容'),
        LegalListItem('VPN 连接仅在主动启动时建立，你随时可以断开'),
      ],
    ),

    // 6. 你的权利
    LegalSection(
      title: '6. 你的权利',
      items: [
        LegalListItem('查看和修改：在应用内随时查看和修改你的网络配置'),
        LegalListItem('删除数据：删除应用内的任何配置信息'),
        LegalListItem('控制连接：随时启停 VPN 连接'),
        LegalListItem('拒绝收集：停止使用本应用即可完全停止信息收集'),
      ],
    ),

    // 7. 第三方服务
    LegalSection(
      title: '7. 第三方服务',
      paragraphs: [
        LegalParagraph('本应用使用了以下第三方库，它们可能遵循各自的隐私政策：'),
      ],
      items: [
        LegalListItem('Flutter（Google）'),
        LegalListItem('device_info_plus'),
        LegalListItem('shared_preferences'),
        LegalListItem('url_launcher'),
      ],
    ),
    LegalSection(
      paragraphs: [
        LegalParagraph('这些库仅在本地运行，不会主动将数据发送至第三方服务器。'),
      ],
    ),

    // 8. 儿童隐私
    LegalSection(
      title: '8. 儿童隐私',
      paragraphs: [
        LegalParagraph('本应用不面向 13 周岁以下的儿童。我们不会有意收集儿童的个人信息。'),
      ],
    ),

    // 9. 变更
    LegalSection(
      title: '9. 隐私政策的变更',
      paragraphs: [
        LegalParagraph('我们可能会不时更新本隐私政策。更新时，我们会在应用内通知你并更新页面顶部的"最后更新日期"。'),
      ],
    ),

    // 10. 联系我们
    LegalSection(
      title: '10. 联系我们',
      paragraphs: [
        LegalParagraph('如果你对本隐私政策有任何疑问或建议，可以通过以下方式联系我们：'),
      ],
      items: [
        LegalListItem('GitHub Issues：https://github.com/vnt-dev/vnt/issues'),
        LegalListItem('官方文档：http://rustvnt.com'),
      ],
    ),
  ];
}
