import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/bookshelf/bookshelf_page.dart';
import '../features/bookshelf/book_detail_page.dart';
import '../features/bookshelf/reader_page.dart';
import '../features/bookshelf/search_page.dart';
import '../features/developer/developer_tools_page.dart';
import '../features/feeds/feed_auth_page.dart';
import '../features/feeds/feeds_page.dart';
import '../features/settings/settings_page.dart';
import '../shared/developer_mode_provider.dart';
import '../shared/theme/fade_slide_page_transitions_builder.dart';
import '../shared/widgets/animated_branch_container.dart';
import '../shared/widgets/main_scaffold.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

CustomTransitionPage<void> _transitionPage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: fadeSlideTransitionDuration,
    reverseTransitionDuration: fadeSlideReverseTransitionDuration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return buildFadeSlideTransition(animation, child);
    },
    child: child,
  );
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/bookshelf',
    routes: [
      StatefulShellRoute(
        builder: (context, state, navigationShell) {
          return MainScaffold(navigationShell: navigationShell);
        },
        navigatorContainerBuilder: (context, navigationShell, children) {
          return AnimatedBranchContainer(
            currentIndex: navigationShell.currentIndex,
            children: children,
          );
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/bookshelf',
                name: 'bookshelf',
                builder: (context, state) => const BookshelfPage(),
                routes: [
                  GoRoute(
                    path: 'search',
                    name: 'bookshelf-search',
                    parentNavigatorKey: _rootNavigatorKey,
                    pageBuilder: (context, state) =>
                        _transitionPage(state, const SearchPage()),
                    routes: [
                      GoRoute(
                        path: 'book',
                        name: 'bookshelf-book-detail',
                        parentNavigatorKey: _rootNavigatorKey,
                        pageBuilder: (context, state) {
                          final feedId =
                              state.uri.queryParameters['feedId'] ?? '';
                          final bookId =
                              state.uri.queryParameters['bookId'] ?? '';
                          final initialBook =
                              state.extra is BookDetailRouteExtra
                              ? state.extra as BookDetailRouteExtra
                              : null;
                          return _transitionPage(
                            state,
                            BookDetailPage(
                              feedId: feedId,
                              bookId: bookId,
                              initialBook: initialBook,
                            ),
                          );
                        },
                        routes: [
                          GoRoute(
                            path: 'read',
                            name: 'bookshelf-reader',
                            parentNavigatorKey: _rootNavigatorKey,
                            pageBuilder: (context, state) {
                              final feedId =
                                  state.uri.queryParameters['feedId'] ?? '';
                              final bookId =
                                  state.uri.queryParameters['bookId'] ?? '';
                              final chapterId =
                                  state.uri.queryParameters['chapterId'] ?? '';
                              final paragraphId =
                                  state.uri.queryParameters['paragraphId'] ??
                                  '';
                              return _transitionPage(
                                state,
                                ReaderPage(
                                  feedId: feedId,
                                  bookId: bookId,
                                  chapterId: chapterId,
                                  paragraphId: paragraphId,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/feeds',
                name: 'feeds',
                builder: (context, state) => const FeedsPage(),
                routes: [
                  GoRoute(
                    path: 'auth',
                    name: 'feed-auth',
                    parentNavigatorKey: _rootNavigatorKey,
                    pageBuilder: (context, state) {
                      final feedId = state.uri.queryParameters['feedId'] ?? '';
                      return _transitionPage(
                        state,
                        FeedAuthPage(feedId: feedId),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                name: 'settings',
                builder: (context, state) => const SettingsPage(),
              ),
            ],
          ),
        ],
      ),
      // The developer tools live outside the shell: a standalone
      // environment, invisible until unlocked (see settings' version row)
      // and rendered above the bottom navigation.
      GoRoute(
        path: '/developer',
        name: 'developer-tools',
        parentNavigatorKey: _rootNavigatorKey,
        redirect: (context, state) =>
            ref.read(developerModeProvider) ? null : '/settings',
        pageBuilder: (context, state) =>
            _transitionPage(state, const DeveloperToolsPage()),
      ),
    ],
  );
});
