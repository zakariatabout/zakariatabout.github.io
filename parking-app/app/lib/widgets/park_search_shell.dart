import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

/// Recherche de destination prête à être posée au-dessus d'une carte.
///
/// Le composant borne sa largeur sur grand écran, conserve une cible tactile de
/// 48 dp et expose explicitement les états de chargement et d'effacement aux
/// technologies d'assistance.
class ParkSearchShell extends StatelessWidget {
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

  void _clear() {
    controller.clear();
    onChanged?.call('');
    onClear?.call();
    focusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Pas de BackdropFilter ici : le flou d'arrière-plan bave hors de son
    // clip sur iOS (Impeller) et voilait la carte entière.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: scheme.surface.withValues(alpha: 0.96),
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shadowColor: Colors.black38,
        borderRadius: ParkRadarRadii.card,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: enabled,
                  autofocus: autofocus,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  textInputAction: TextInputAction.search,
                  keyboardType: TextInputType.streetAddress,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: label,
                    hintText: hint,
                    prefixIcon: const ExcludeSemantics(
                      child: Icon(Icons.search),
                    ),
                    suffixIcon: isLoading
                        ? Semantics(
                            liveRegion: true,
                            label: loadingLabel,
                            child: const Padding(
                              padding: EdgeInsets.all(ParkRadarSpacing.sm),
                              child: SizedBox.square(
                                dimension: ParkRadarSizes.icon,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          )
                        : value.text.isNotEmpty
                        ? IconButton(
                            onPressed: enabled ? _clear : null,
                            tooltip: clearTooltip,
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
                      horizontal: ParkRadarSpacing.md,
                      vertical: ParkRadarSpacing.sm,
                    ),
                    constraints: const BoxConstraints(
                      minHeight: ParkRadarSizes.searchFieldHeight,
                    ),
                  ),
                );
              },
            ),
            if (suggestions != null) ...[
              Divider(color: scheme.outlineVariant),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: suggestionsMaxHeight),
                child: suggestions!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
