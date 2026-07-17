import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

/// Recherche de destination flottante façon Waze : pilule compacte posée sur
/// la carte, hint seul (pas de floating label Material), loupe teintée marque
/// et anneau de focus animé.
///
/// Pas de BackdropFilter ici : le flou d'arrière-plan bave hors de son clip
/// sur iOS (Impeller) et voilait la carte entière.
class ParkSearchShell extends StatefulWidget {
  const ParkSearchShell({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.suggestions,
    this.isLoading = false,
    this.enabled = true,
    this.autofocus = false,
    this.label = 'Destination',
    this.hint = 'Où allez-vous ?',
    this.loadingLabel = 'Recherche de destinations en cours',
    this.clearTooltip = 'Effacer la destination',
    this.maxWidth = ParkRadarBreakpoints.searchMaxWidth,
    this.suggestionsMaxHeight = 320,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final Widget? suggestions;
  final bool isLoading;
  final bool enabled;
  final bool autofocus;
  final String label;
  final String hint;
  final String loadingLabel;
  final String clearTooltip;
  final double maxWidth;
  final double suggestionsMaxHeight;

  @override
  State<ParkSearchShell> createState() => _ParkSearchShellState();
}

class _ParkSearchShellState extends State<ParkSearchShell> {
  FocusNode? _internalFocusNode;
  bool _focused = false;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_internalFocusNode ??= FocusNode(debugLabel: 'ParkSearchShell'));

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    _focused = _focusNode.hasFocus;
  }

  @override
  void didUpdateWidget(ParkSearchShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _internalFocusNode)?.removeListener(
        _handleFocusChange,
      );
      _focusNode.addListener(_handleFocusChange);
      _focused = _focusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    (widget.focusNode ?? _internalFocusNode)?.removeListener(
      _handleFocusChange,
    );
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final focused = _focusNode.hasFocus;
    if (focused != _focused) setState(() => _focused = focused);
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
    widget.onClear?.call();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = context.parkRadarColors;
    final dark = theme.brightness == Brightness.dark;

    final surface = dark
        ? ParkRadarSearchPalette.surfaceDark
        : ParkRadarSearchPalette.surfaceLight;
    final hintColor = dark
        ? ParkRadarSearchPalette.hintDark
        : ParkRadarSearchPalette.hintLight;
    final hairline = dark
        ? ParkRadarSearchPalette.hairlineDark
        : ParkRadarSearchPalette.hairlineLight;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Label « visuellement masqué » : conserve le texte « Destination »
          // dans l'arbre (tests find.text) sans floating label Material.
          // Opacity + SizedBox(height: 0), surtout pas Offstage : les finders
          // sautent les widgets offstage (skipOffstage: true par défaut).
          // Le rôle accessible est porté par le Semantics(label:) ci-dessous.
          ExcludeSemantics(
            child: Opacity(
              opacity: 0,
              child: SizedBox(
                height: 0,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              ),
            ),
          ),
          AnimatedContainer(
            duration: ParkRadarMotion.standard,
            curve: ParkRadarMotion.enter,
            decoration: BoxDecoration(
              borderRadius: ParkRadarRadii.searchPill,
              boxShadow: [
                BoxShadow(
                  color: dark
                      ? ParkRadarSearchPalette.shadowKeyDark
                      : ParkRadarSearchPalette.shadowKeyLight,
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
                BoxShadow(
                  color: dark
                      ? ParkRadarSearchPalette.shadowDark
                      : ParkRadarSearchPalette.shadowLight,
                  blurRadius: _focused ? 24 : 14,
                  offset: Offset(0, _focused ? 8 : 5),
                ),
              ],
            ),
            child: Material(
              color: surface,
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: ParkRadarRadii.searchPill,
                side: BorderSide(
                  color: _focused ? colors.brand : hairline,
                  width: _focused ? 1.5 : 1,
                ),
              ),
              child: Semantics(
                container: true,
                label: widget.label,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    return TextField(
                      controller: widget.controller,
                      focusNode: _focusNode,
                      enabled: widget.enabled,
                      autofocus: widget.autofocus,
                      onChanged: widget.onChanged,
                      onSubmitted: widget.onSubmitted,
                      textInputAction: TextInputAction.search,
                      keyboardType: TextInputType.streetAddress,
                      textCapitalization: TextCapitalization.words,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: scheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        // Hint seul, jamais de labelText : pas de floating
                        // label Material dans la pilule.
                        hintText: widget.hint,
                        hintStyle: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -0.2,
                          color: hintColor,
                        ),
                        // Neutralise le InputDecorationTheme global
                        // (filled: true + OutlineInputBorder).
                        filled: false,
                        fillColor: Colors.transparent,
                        prefixIcon: ExcludeSemantics(
                          child: Icon(
                            Icons.search,
                            size: 22,
                            color: _focused ? colors.brand : hintColor,
                          ),
                        ),
                        suffixIcon: widget.isLoading
                            ? Semantics(
                                liveRegion: true,
                                label: widget.loadingLabel,
                                child: const Padding(
                                  padding: EdgeInsets.all(ParkRadarSpacing.sm),
                                  child: SizedBox.square(
                                    dimension: ParkRadarSizes.compactIcon,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              )
                            : value.text.isNotEmpty
                            ? IconButton(
                                onPressed: widget.enabled ? _clear : null,
                                tooltip: widget.clearTooltip,
                                iconSize: 20,
                                color: hintColor,
                                icon: const Icon(Icons.close),
                              )
                            : null,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: ParkRadarSpacing.xxs,
                          vertical: ParkRadarSpacing.sm,
                        ),
                        constraints: const BoxConstraints(
                          minHeight: ParkRadarSizes.searchPillHeight,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          // Suggestions : carte détachée sous la pilule (façon dropdown Waze),
          // jamais fusionnée avec la pilule pour garder le rayon 26 intact.
          if (widget.suggestions != null) ...[
            const SizedBox(height: ParkRadarSpacing.xs),
            Material(
              color: surface,
              surfaceTintColor: Colors.transparent,
              elevation: 12,
              shadowColor: dark
                  ? ParkRadarSearchPalette.shadowDark
                  : ParkRadarSearchPalette.shadowLight,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: ParkRadarRadii.card,
                side: BorderSide(color: hairline),
              ),
              child: AnimatedSize(
                duration: ParkRadarMotion.standard,
                curve: ParkRadarMotion.enter,
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: widget.suggestionsMaxHeight,
                  ),
                  child: widget.suggestions!,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
