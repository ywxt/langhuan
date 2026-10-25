import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/bookshelf/bookshelf_page.dart';
import '../features/bookshelf/book_detail_page.dart';
import '../features/bookshelf/reader_page.dart';
import '../features/bookshelf/search_page.dart';
import '../features/feeds/feed_auth_page.dart';
import '../features/feeds/feeds_page.dart';
import '../features/settings/settings_page.dart';
import '../shared/widgets/main_scaffold.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/bookshelf',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainScaffold(navigationShell: navigationShell);
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
                    builder: (context, state) => const SearchPage(),
                    routes: [
                      GoRoute(
                        path: 'book',
                        name: 'bookshelf-book-detail',
                        parentNavigatorKey: _rootNavigatorKey,
                        builder: (context, state) {
                          final feedId =
                              state.uri.queryParameters['feedId'] ?? '';
                          final bookId =
                              state.uri.queryParameters['bookId'] ?? '';
                          return BookDetailPage(
                            feedId: feedId,
                            bookId: bookId,
                          );
                        },
                        routes: [
                          GoRoute(
                            path: 'read',
                            name: 'bookshelf-reader',
                            parentNavigatorKey: _rootNavigatorKey,
                            builder: (context, state) {
                              final feedId =
                                  state.uri.queryParameters['feedId'] ?? '';
                              final bookId =
                                  state.uri.queryParameters['bookId'] ?? '';
                              final chapterId =
                                  state.uri.queryParameters['chapterId'] ?? '';
                              final paragraphId =
                                  state
                                          .uri
                                          .queryParameters['paragraphId'] ??
                                      '';
                              return ReaderPage(
                                feedId: feedId,
                                bookId: bookId,
                                chapterId: chapterId,
                                paragraphId: paragraphId,
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
                    builder: (context, state) {
                      final feedId = state.uri.queryParameters['feedId'] ?? '';
                      return FeedAuthPage(feedId: feedId);
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
    ],
  );
});
