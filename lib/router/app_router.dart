import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/bookshelf/bookshelf_page.dart';
import '../features/bookshelf/book_detail_page.dart';
import '../features/bookshelf/reader_page.dart';
import '../features/bookshelf/search_page.dart';
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
                        pageBuilder: (context, state) {
                          final feedId =
                              state.uri.queryParameters['feedId'] ?? '';
                          final bookId =
                              state.uri.queryParameters['bookId'] ?? '';
                          return CustomTransitionPage(
                            key: state.pageKey,
                            child: BookDetailPage(
                              feedId: feedId,
                              bookId: bookId,
                            ),
                            transitionsBuilder:
                                (
                                  context,
                                  animation,
                                  secondaryAnimation,
                                  child,
                                ) {
                                  return FadeTransition(
                                    opacity: CurveTween(
                                      curve: Curves.easeOut,
                                    ).animate(animation),
                                    child: SlideTransition(
                                      position:
                                          Tween<Offset>(
                                                begin: const Offset(0, 0.05),
                                                end: Offset.zero,
                                              )
                                              .chain(
                                                CurveTween(
                                                  curve: Curves.easeOut,
                                                ),
                                              )
                                              .animate(animation),
                                      child: child,
                                    ),
                                  );
                                },
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
                              final paragraphIndex =
                                  int.tryParse(
                                    state
                                            .uri
                                            .queryParameters['paragraphIndex'] ??
                                        '',
                                  ) ??
                                  0;
                              return ReaderPage(
                                feedId: feedId,
                                bookId: bookId,
                                chapterId: chapterId,
                                paragraphIndex: paragraphIndex,
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
