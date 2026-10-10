# NewPipe pour iOS (Swift natif)

Port iOS natif (Swift/SwiftUI) de [NewPipe](https://github.com/TeamNewPipe/NewPipe), le client YouTube libre
pour Android : **sans compte Google, sans publicité, sans traqueurs**, sans API officielle.
S'y ajoutent des fonctions **anti-distraction** (Shorts, commentaires, suggestions masquables, rappels de pause).

## Porter NewPipe sur iOS

NewPipe Android repose sur deux projets Java/Kotlin :
[NewPipe](https://github.com/TeamNewPipe/NewPipe) (l'app) et
[NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor) (la bibliothèque qui lit YouTube sans API).
Aucun des deux ne peut tourner tel quel sur iOS : pas de JVM, pas de lecteur ExoPlayer, pas de services Android,
et l'extracteur s'appuie sur Rhino (un moteur JavaScript Java) pour déchiffrer les URL de flux.

Ce dépôt est donc une **réécriture complète en Swift**, qui reprend l'architecture et les principes de NewPipe
mais avec les équivalents natifs d'iOS. Aucune ligne de code Java n'est réutilisée.

### Correspondance des composants

| NewPipe Android | Ce port iOS |
|---|---|
| NewPipeExtractor (Java) | `Packages/NewPipeExtractor` (Swift Package) : mêmes principes, imitation des clients InnerTube `youtubei/v1` |
| Déchiffrement des signatures et du paramètre `n` (JavaScript via Rhino) | Inutile : les clients VISIONOS, IOS et ANDROID_VR renvoient des URL non chiffrées et un manifeste HLS |
| ExoPlayer / Media3, flux DASH | `AVPlayer` + flux **HLS**, lu nativement par iOS |
| Lecteur en arrière-plan (service + notification) | Session audio `.playback`, Now Playing et commandes à distance (écran verrouillé, Centre de contrôle) |
| Lecteur popup | Picture-in-Picture natif |
| Téléchargeur (missions, tranches HTTP) | `HLSDownloader` : segments HLS, vidéo MPEG-TS remuxée en MP4 sans réencodage, audio AAC |
| Base Room (SQLite) | SwiftData |
| SharedPreferences | `UserDefaults` / `@AppStorage` |
| Flux d'abonnements, « mode rapide » RSS | Même flux RSS public des chaînes |
| Import/export des abonnements (`.json`) | **Même format** : un export NewPipe Android s'importe ici, et inversement |
| Import Google Takeout (`subscriptions.csv`) | Pris en charge |
| Commentaires (`CommentsInfo`) | `Parsers.comments` (nouveau format `commentEntityPayload` de YouTube) |
| Intents « Partager » / liens YouTube | Liens collés dans la recherche + schéma `newpipe://open?url=…` |
| Services SoundCloud, PeerTube, Bandcamp, media.ccc.de | Non portés : YouTube uniquement |
| Tendances / kiosques | Non portés |

### Ce qui est propre à iOS

- **Lecture sans PO token.** Depuis 2025, YouTube coupe les URL directes après la première minute sans
  « PO token » (jeton anti-robot BotGuard). Le flux HLS du client **VISIONOS** (le même qu'utilise yt-dlp) se lit
  en entier sans jeton : il sert à la lecture comme aux téléchargements.
- **Piste audio d'origine.** Les vidéos doublées proposent une vingtaine de pistes audio ; iOS choisirait le
  doublage dans la langue du téléphone. L'app sélectionne la version originale (identifiant de piste en `.4`),
  les doublages restant disponibles dans le menu audio du lecteur.
- **Plein écran** natif d'iOS, à l'horizontale (bouton ou rotation du téléphone) ; le reste de l'app reste en portrait.
- **Concentration** (voir plus bas), absente de NewPipe Android.

### Compatibilité des données

| Donnée | Échange avec NewPipe Android |
|---|---|
| Abonnements | ✅ Export et import au format NewPipe (`newpipe_subscriptions.json`) |
| Historique, playlists locales | ❌ L'export complet de NewPipe (`.zip` de base de données) n'est pas lu |
| Réglages | ❌ Propres à chaque app |

## Fonctionnalités

| NewPipe Android | iOS |
|---|---|
| Recherche + suggestions + filtres (vidéos/chaînes/playlists), historique de recherche | ✅ |
| Lecture vidéo, résolution max, vitesse, AirPlay | ✅ HLS via AVPlayer, plein écran à l'horizontale |
| Lecture en arrière-plan (audio seul) / popup | ✅ arrière-plan + Picture-in-Picture |
| File d'attente (lire ensuite, ajouter, réordonner), lecture auto de la suivante | ✅ |
| Contrôles écran verrouillé / Centre de contrôle | ✅ |
| Reprise de la lecture, historique de visionnage | ✅ |
| Abonnements sans compte, flux « Nouveautés » (RSS) | ✅ uniquement les vidéos publiées après l'abonnement (réglable) |
| Import/export des abonnements (NewPipe .json, Google Takeout .csv) | ✅ |
| Playlists locales, playlists YouTube en favoris | ✅ |
| Téléchargement vidéo (MP4 jusqu'en 1080p) / audio (M4A) | ✅ visibles dans l'app Fichiers |
| Ouverture de liens collés (vidéo, chaîne, @handle, playlist) | ✅ + `newpipe://open?url=…` |
| Commentaires (avec réponses) | ✅ visibles, sur demande ou masqués |
| Directs (live) | ⚠️ YouTube ne fournit plus de HLS sans connexion : message d'erreur |
| Chapitres, SponsorBlock, SoundCloud/PeerTube/Bandcamp | ❌ pas encore |

## Concentration (Réglages › Concentration)

- **Mode concentration** : un interrupteur qui applique tous les réglages ci-dessous et restaure les précédents quand on l'éteint.
- Masquer les **Shorts** (recherche, chaînes, Nouveautés, suggestions, lecture automatique).
- **Commentaires** et **suggestions** : visibles, sur demande (bouton) ou masqués.
- Masquer les **compteurs** (vues, « J'aime », abonnés), **miniatures** normales/floutées/masquées, **titres apaisés**.
- Désactiver les suggestions de recherche et la lecture automatique ; **rappel de pause** après N minutes.
- **Temps de visionnage** des 7 derniers jours.

## Structure

```
NewPipe.xcodeproj               Projet Xcode (dossiers synchronisés, Xcode 16+)
Config/Info.plist               Audio en arrière-plan, partage de fichiers, schéma newpipe://
Scripts/testflight.sh           Archive et envoi sur TestFlight
Packages/NewPipeExtractor/      Équivalent Swift de NewPipeExtractor (InnerTube)
  Sources/NewPipeExtractor/       YouTubeService, InnerTubeClient, Parsers, RSS, modèles
  Sources/extractor-cli/          Outil de test en ligne de commande
NewPipe/
  App/        Point d'entrée, onglets, réglages, mode concentration
  Player/     Lecteur (AVPlayer) : file d'attente, arrière-plan, PiP, plein écran, commentaires
  Views/      Recherche, chaîne, playlist, nouveautés, abonnements, bibliothèque, réglages, thème
  Data/       SwiftData (abonnements, historique, playlists), flux, import/export
  Downloads/  Téléchargements vidéo/audio (HLS → MP4/M4A)
```

## Fonctionnement de l'extracteur

Comme NewPipeExtractor, il imite plusieurs clients InnerTube (`youtubei/v1`) :
- **WEB** : recherche, page vidéo et commentaires (`next`), chaînes et playlists (`browse`) ;
- **VISIONOS** : `player` → manifeste **HLS** lisible en entier sans PO token (lecture et téléchargements) ;
- **IOS** : `player` → HLS de secours ;
- **ANDROID_VR** : `player` → URL directes (repli quand il n'y a pas de HLS ; coupées après ~1 min sans PO token).

Les versions des clients sont dans `InnerTubeClient.swift` (`InnerTubeProfile`). Quand YouTube casse quelque chose,
c'est là qu'il faut regarder en premier, en comparant avec le client `visionos` de yt-dlp :

```bash
grep -A 14 "'visionos'" /opt/homebrew/Cellar/yt-dlp/*/libexec/lib/python*/site-packages/yt_dlp/extractor/youtube/_base.py
```

Tester l'extracteur sans l'app :

```bash
cd Packages/NewPipeExtractor
swift run extractor-cli search "lofi"
swift run extractor-cli stream dQw4w9WgXcQ
swift run extractor-cli comments dQw4w9WgXcQ
swift run extractor-cli hls dQw4w9WgXcQ
swift run extractor-cli channel UCSJ4gkVC6NrvII8umztf0Ow
```

## Compiler et installer

1. Sélectionner Xcode et accepter sa licence : `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept`
2. Ouvrir `NewPipe.xcodeproj` et choisir votre équipe dans *Signing & Capabilities*, avec un identifiant de bundle à vous.
3. Lancer sur un iPhone ou un simulateur (iOS 17+).

Cette app ne peut pas être publiée sur l'App Store (règles d'Apple concernant YouTube). Installez-la depuis Xcode,
par TestFlight en test interne, ou par sideloading (AltStore, SideStore).

### Installer sur son iPhone via TestFlight

1. **Xcode › Réglages › Comptes** : ajouter son identifiant Apple (compte développeur).
2. **App Store Connect › Apps › « + » › Nouvelle app** : plateforme iOS, un nom, et votre identifiant de bundle.
3. Dans Xcode : **Product › Archive**, puis **Distribute App › TestFlight Internal Only**.
   (Ou `Scripts/testflight.sh com.monnom.newpipe` en ligne de commande.)
4. Après 10-20 min de traitement : **App Store Connect › TestFlight › Tests internes**, créer un groupe, s'y ajouter.
   Installer l'app **TestFlight** sur l'iPhone et accepter l'invitation. Pas de validation Apple pour les tests internes.

## Licence

GPLv3, comme NewPipe. NewPipe et NewPipeExtractor sont des projets de la
[Team NewPipe](https://github.com/TeamNewPipe) ; ce port n'est pas affilié à leur projet.
