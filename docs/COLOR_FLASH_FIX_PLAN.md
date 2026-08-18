# Fix Plan: Colour Flash When Switching Songs / Opening the Player

**File to edit:** `app/lib/main.dart` (one edit, one function: `PearMusicApp.build`)

## Root cause (verified against Flutter's actual source, not guessed)

In `main.dart`, the animated colour fade only wraps `home:`:

```dart
return MaterialApp(
  theme: theme,                 // target colour, applied INSTANTLY
  home: TweenAnimationBuilder<ThemeData>(
    tween: _ThemeTween(begin: theme, end: theme),
    ...
    builder: (context, animatedTheme, _) => Theme(
      data: animatedTheme,
      child: const _MessagesListener(child: HomeShell()),
    ),
  ),
);
```

`MaterialApp.home` becomes the **first route only**. Any route you `push()`
to later (the player page, playlists, settings) is built by the Navigator's
`Overlay` as a **sibling** of that first route — it is *not* a descendant of
the `Theme(data: animatedTheme, ...)` wrapper above. So pushed routes fall
back to `MaterialApp.theme` directly, which — as the comment in the file
admits — is the **target colour, applied instantly, no animation**.

Net effect: the library page (still mid-fade or on the old colour) pushes
the player page, which snaps straight to the new target colour with zero
transition — visible as a flash, most noticeable when it lands near the
purple/blue fallback tone (`ArtworkPalette.fallback`) partway through the
fade.

*(One thing I suspected earlier and want to correct: I thought
`_ThemeTween(begin: theme, end: theme)` itself broke the animation. I
checked Flutter's actual `TweenAnimationBuilder` source — it only ever uses
`tween.end` after the first build and re-derives `begin` from the current
animated value itself, so that part is harmless, just redundant. Not the
bug.)*

## The fix

Move the animated `Theme` wrapper from `home:` to `MaterialApp.builder:`.
`builder` wraps the **whole Navigator** (every route, pushed or not), so
the fade applies everywhere instead of just the first page.

**FIND THIS** (in `PearMusicApp.build`):

```dart
          return MaterialApp(
            title: 'Pear Music',
            debugShowCheckedModeBanner: false,
            // The app theme is the TARGET colour, applied instantly. Animating
            // MaterialApp.theme rebuilt the WHOLE tree (Navigator + every route)
            // on every frame of the fade — that was the mobile lag. Instead only
            // the current screen fades below; pushed routes (player, playlists)
            // use the target colour directly, and the player has its own cheap
            // artwork-colour wash animation for the visible fade.
            theme: theme,
            home: TweenAnimationBuilder<ThemeData>(
              tween: _ThemeTween(begin: theme, end: theme),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              builder: (context, animatedTheme, _) => Theme(
                data: animatedTheme,
                child: const _MessagesListener(child: HomeShell()),
              ),
            ),
          );
```

**REPLACE WITH:**

```dart
          return MaterialApp(
            title: 'Pear Music',
            debugShowCheckedModeBanner: false,
            // `theme` is only a same-frame fallback for the sliver of time
            // before `builder` below mounts. The actual fade happens in
            // `builder`, which wraps the WHOLE Navigator — home AND every
            // pushed route (player, playlists, settings) — so switching
            // songs or navigating never snaps to a different, un-animated
            // colour partway through a fade.
            theme: theme,
            home: const _MessagesListener(child: HomeShell()),
            builder: (context, child) => TweenAnimationBuilder<ThemeData>(
              tween: _ThemeTween(end: theme),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              builder: (context, animatedTheme, child) => Theme(
                data: animatedTheme,
                child: child!,
              ),
              child: child,
            ),
          );
```

Note `_ThemeTween(end: theme)` — `begin:` dropped since (per above) it was
never actually used past the first frame; removing it avoids implying it
does something it doesn't.

## Why this shouldn't reintroduce the old mobile-lag problem

The comment on the original code warns that animating `MaterialApp.theme`
directly caused lag because it rebuilt the *whole tree* every frame. This
fix does **not** do that — `theme:` stays a static, instantly-set value
exactly as before. Only the `TweenAnimationBuilder`'s own `Theme` wrapper
rebuilds per frame, same cost as today, just repositioned so it wraps the
Navigator (and therefore every route) instead of only `home`.

## Verification

```bash
cd app
flutter analyze          # no new errors
flutter test test/theme_transition_test.dart   # existing theme test must still pass
```

Manual check: play a song, then immediately open the player page (or switch
songs while the player page is open) — the colour should fade smoothly with
no snap/flash, on both the page you're leaving and the one you're entering.

`theme_transition_test.dart` only tests the colour-lerp math directly
(`ColorScheme.lerp`/`copyWith`), not the widget tree — checked it, unaffected
by this edit, no update needed there.
