/// Cache mémoire à durée de vie, avec éviction LRU.
///
/// Objectif produit : re-sélectionner la même destination ne doit pas
/// re-télécharger l'inventaire Paris Data ni le réseau viaire Overpass
/// (constat de l'audit : aucun cache, re-téléchargement intégral à chaque
/// recherche). La date métier des données (`sourceUpdatedAt`) reste celle du
/// fournisseur : ce cache ne rajeunit jamais une donnée, il évite seulement
/// un transfert identique.
class TtlCache<K, V> {
  TtlCache({
    required this.ttl,
    this.maxEntries = 32,
    DateTime Function()? clock,
  }) : assert(maxEntries > 0, 'maxEntries doit être positif'),
       _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _clock;

  // LinkedHashMap : l'ordre d'insertion sert d'ordre LRU (réinsertion à
  // chaque accès réussi).
  final Map<K, _TtlEntry<V>> _entries = {};

  V? get(K key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (_clock().difference(entry.storedAt) > ttl) {
      _entries.remove(key);
      return null;
    }
    // Rafraîchit la position LRU sans toucher à la date de stockage.
    _entries.remove(key);
    _entries[key] = entry;
    return entry.value;
  }

  void set(K key, V value) {
    _entries.remove(key);
    _entries[key] = _TtlEntry(value: value, storedAt: _clock());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  int get length => _entries.length;

  void clear() => _entries.clear();
}

class _TtlEntry<V> {
  const _TtlEntry({required this.value, required this.storedAt});

  final V value;
  final DateTime storedAt;
}
