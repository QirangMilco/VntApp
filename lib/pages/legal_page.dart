import 'package:flutter/material.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';

/// 法律文档页面组件
/// 可复用：传入标题和章节列表即可渲染隐私政策、用户协议等
class LegalPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<LegalSection> sections;
  final String? lastUpdated;

  const LegalPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.sections,
    this.lastUpdated,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, isDark),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  context.spacingMedium,
                  0,
                  context.spacingMedium,
                  context.spacingXLarge,
                ),
                children: [
                  _buildTitleSection(context, isDark),
                  ...sections.map((section) => _buildSection(context, isDark, section)),
                  SizedBox(height: context.spacingLarge),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.spacingMedium,
        context.spacingSmall,
        context.spacingMedium,
        context.spacingSmall,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.15 : 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_back_rounded,
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          SizedBox(width: context.spacingSmall),
          Text(
            title,
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w600,
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleSection(BuildContext context, bool isDark) {
    return Padding(
      padding: EdgeInsets.only(
        top: context.spacingLarge,
        bottom: context.spacingMedium,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitle,
            style: TextStyle(
              fontSize: context.fontXLarge,
              fontWeight: FontWeight.bold,
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          if (lastUpdated != null) ...[
            SizedBox(height: context.spacingXSmall),
            Text(
              '最后更新：$lastUpdated',
              style: TextStyle(
                fontSize: context.fontSmall,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ],
          SizedBox(height: context.spacingMedium),
          Divider(
            color: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.08),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, bool isDark, LegalSection section) {
    final primaryColor = Theme.of(context).primaryColor;

    return Padding(
      padding: EdgeInsets.only(bottom: context.spacingMedium),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (section.title != null)
            Padding(
              padding: EdgeInsets.only(bottom: context.spacingSmall),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 4,
                    height: context.fontXLarge + 4,
                    decoration: BoxDecoration(
                      color: primaryColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  SizedBox(width: context.spacingSmall),
                  Expanded(
                    child: Text(
                      section.title!,
                      style: TextStyle(
                        fontSize: context.fontXLarge,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (section.subSections != null)
            ...section.subSections!.map((sub) => _buildSubSection(context, isDark, sub)),
          if (section.paragraphs != null)
            ...section.paragraphs!.map((p) => _buildParagraph(context, isDark, p)),
          if (section.items != null)
            ...section.items!.map((item) => _buildListItem(context, isDark, item)),
        ],
      ),
    );
  }

  Widget _buildSubSection(BuildContext context, bool isDark, LegalSubSection sub) {
    return Padding(
      padding: EdgeInsets.only(
        left: context.spacingSmall,
        top: context.spacingSmall,
        bottom: context.spacingXSmall,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sub.title != null)
            Padding(
              padding: EdgeInsets.only(bottom: context.spacingXSmall),
              child: Text(
                sub.title!,
                style: TextStyle(
                  fontSize: context.fontMedium,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                ),
              ),
            ),
          if (sub.paragraphs != null)
            ...sub.paragraphs!.map((p) => _buildParagraph(context, isDark, p)),
          if (sub.items != null)
            ...sub.items!.map((item) => _buildListItem(context, isDark, item)),
        ],
      ),
    );
  }

  Widget _buildParagraph(BuildContext context, bool isDark, LegalParagraph para) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.spacingXSmall),
      child: Text(
        para.text,
        style: TextStyle(
          fontSize: context.fontBody,
          height: 1.7,
          color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
        ),
      ),
    );
  }

  Widget _buildListItem(BuildContext context, bool isDark, LegalListItem item) {
    return Padding(
      padding: EdgeInsets.only(
        left: context.spacingMedium,
        bottom: context.spacingSmall,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ',
            style: TextStyle(
              fontSize: context.fontBody,
              height: 1.7,
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          Expanded(
            child: item.isBold
                ? RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: context.fontBody,
                        height: 1.7,
                        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                      ),
                      children: [
                        TextSpan(
                          text: item.prefix,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        TextSpan(text: item.text),
                      ],
                    ),
                  )
                : Text(
                    item.text,
                    style: TextStyle(
                      fontSize: context.fontBody,
                      height: 1.7,
                      color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── 数据模型 ───

class LegalSection {
  final String? title;
  final List<LegalSubSection>? subSections;
  final List<LegalParagraph>? paragraphs;
  final List<LegalListItem>? items;

  const LegalSection({
    this.title,
    this.subSections,
    this.paragraphs,
    this.items,
  });
}

class LegalSubSection {
  final String? title;
  final List<LegalParagraph>? paragraphs;
  final List<LegalListItem>? items;

  const LegalSubSection({this.title, this.paragraphs, this.items});
}

class LegalParagraph {
  final String text;

  const LegalParagraph(this.text);
}

class LegalListItem {
  final String text;
  final String? prefix;
  final bool isBold;

  const LegalListItem(this.text, {this.prefix, this.isBold = false});
}
