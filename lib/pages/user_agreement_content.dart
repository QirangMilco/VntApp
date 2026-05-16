import 'legal_page.dart';

/// 用户协议内容
class UserAgreementContent {
  static const String title = '用户协议';
  static const String subtitle = 'Terms of Service';
  static const String lastUpdated = '2026 年 5 月 16 日';

  static const List<LegalSection> sections = [
    // 引言
    LegalSection(
      paragraphs: [
        LegalParagraph('欢迎使用 VNT App（以下简称"本应用"）。请仔细阅读以下用户协议（以下简称"本协议"）。安装、使用本应用即表示你已阅读、理解并同意受本协议约束。'),
      ],
    ),

    // 1. 协议的接受
    LegalSection(
      title: '1. 协议的接受',
      paragraphs: [
        LegalParagraph('通过下载、安装或使用本应用，你确认：'),
      ],
      items: [
        LegalListItem('你已年满 13 周岁（或你所在司法辖区规定的其他年龄）'),
        LegalListItem('你具有完全民事行为能力'),
        LegalListItem('你同意遵守本协议的全部条款'),
      ],
    ),
    LegalSection(
      paragraphs: [
        LegalParagraph('如你不同意本协议的任何条款，请勿安装或使用本应用。'),
      ],
    ),

    // 2. 许可授予
    LegalSection(
      title: '2. 许可授予',
      paragraphs: [
        LegalParagraph('本应用基于 Apache License 2.0 开源许可证发布。在此许可下，我们授予你非排他性的、不可转让的许可，允许你在个人设备上安装和使用本应用。'),
      ],
    ),

    // 3. 使用规范
    LegalSection(
      title: '3. 使用规范',
      subSections: [
        LegalSubSection(
          title: '3.1 允许的行为',
          items: [
            LegalListItem('在个人设备上安装和使用本应用建立虚拟组网'),
            LegalListItem('在遵守开源许可的前提下查看、修改源代码'),
            LegalListItem('在合理范围内使用本应用进行技术学习和研究'),
          ],
        ),
        LegalSubSection(
          title: '3.2 禁止的行为',
          items: [
            LegalListItem('利用本应用从事任何违法活动，包括但不限于网络攻击、入侵他人网络、传播恶意软件'),
            LegalListItem('利用本应用侵犯他人合法权益，包括但不限于隐私权、知识产权'),
            LegalListItem('逆向工程、反编译或破解本应用的付费功能（如有）'),
            LegalListItem('使用本应用绕过法律法规规定的网络访问限制用于非法目的'),
            LegalListItem('将本应用用于任何可能危害网络安全的用途'),
          ],
        ),
      ],
    ),

    // 4. 知识产权
    LegalSection(
      title: '4. 知识产权',
      items: [
        LegalListItem('本应用的源代码遵循 Apache License 2.0 开源协议'),
        LegalListItem('本应用的名称、图标、品牌标识归开发者所有'),
        LegalListItem('本应用的底层 VNT 组网引擎（vnt）遵循其自身的开源许可证'),
      ],
    ),

    // 5. 免责声明
    LegalSection(
      title: '5. 免责声明',
      subSections: [
        LegalSubSection(
          title: '5.1 服务"按原样"提供',
          paragraphs: [
            LegalParagraph('本应用按"原样"和"可用"的基础提供。我们不作任何明示或暗示的保证，包括但不限于：'),
          ],
          items: [
            LegalListItem('适销性保证'),
            LegalListItem('特定用途适用性保证'),
            LegalListItem('不侵权保证'),
            LegalListItem('服务不间断、及时、安全或无错误的保证'),
          ],
        ),
        LegalSubSection(
          title: '5.2 网络连接',
          paragraphs: [
            LegalParagraph('虚拟组网连接的稳定性和速度受多种因素影响，包括但不限于你的网络环境、服务器状态、距离等。我们不保证连接始终可用或达到特定性能水平。'),
          ],
        ),
        LegalSubSection(
          title: '5.3 使用风险',
          paragraphs: [
            LegalParagraph('你理解并同意，使用本应用的风险由你自行承担。你应对通过本应用传输的数据和进行的操作负全部责任。'),
          ],
        ),
      ],
    ),

    // 6. 责任限制
    LegalSection(
      title: '6. 责任限制',
      paragraphs: [
        LegalParagraph('在法律允许的最大范围内，我们对因使用或无法使用本应用而导致的任何直接、间接、偶然、特殊或后果性损害不承担责任，包括但不限于数据丢失、业务中断、利润损失。'),
      ],
    ),

    // 7. 终止
    LegalSection(
      title: '7. 终止',
      paragraphs: [
        LegalParagraph('我们保留在任何时候、以任何理由终止你使用本应用的权利，恕不另行通知。终止后，你应立即停止使用本应用并删除其副本。'),
      ],
    ),

    // 8. 第三方内容
    LegalSection(
      title: '8. 第三方内容',
      paragraphs: [
        LegalParagraph('本应用可能包含指向第三方网站或服务的链接。我们不对这些第三方的内容、隐私政策或行为负责。'),
      ],
    ),

    // 9. 争议解决
    LegalSection(
      title: '9. 争议解决',
      paragraphs: [
        LegalParagraph('本协议的解释、效力及争议解决适用中华人民共和国法律。因本协议引起的争议，双方应友好协商解决；协商不成的，提交开发者所在地有管辖权的法院诉讼解决。'),
      ],
    ),

    // 10. 变更
    LegalSection(
      title: '10. 协议的变更',
      paragraphs: [
        LegalParagraph('我们可能会不时修改本协议。重大变更会在应用内通知你。修改后的协议自发布之日起生效，继续使用本应用即表示你接受修改后的协议。'),
      ],
    ),

    // 11. 其他
    LegalSection(
      title: '11. 其他',
      items: [
        LegalListItem('本协议的任何条款被认定为无效或不可执行，不影响其他条款的效力'),
        LegalListItem('本协议构成你与我们之间关于本应用的完整协议'),
        LegalListItem('我们的未能执行本协议的任何条款不构成对该权利的放弃'),
      ],
    ),

    // 12. 联系我们
    LegalSection(
      title: '12. 联系我们',
      paragraphs: [
        LegalParagraph('如对本协议有任何疑问，请通过以下方式联系我们：'),
      ],
      items: [
        LegalListItem('GitHub Issues：https://github.com/vnt-dev/vnt/issues'),
        LegalListItem('官方文档：http://rustvnt.com'),
      ],
    ),
  ];
}
