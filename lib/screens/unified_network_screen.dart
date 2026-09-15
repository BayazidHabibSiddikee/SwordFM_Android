import 'package:flutter/material.dart';
import '../theme/theme.dart';
import 'network_screen.dart';
import 'cloud_browser_screen.dart';

class UnifiedNetworkScreen extends StatelessWidget {
  const UnifiedNetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(kTextTabBarHeight),
          child: SafeArea(
            child: Material(
              color: OneDarkColors.bgDark,
              child: TabBar(
                indicatorColor: OneDarkColors.cyan,
                labelColor: OneDarkColors.cyan,
                unselectedLabelColor: OneDarkColors.fgDim,
                tabs: const [
                  Tab(icon: Icon(Icons.cloud_queue), text: 'Cloud Drives'),
                  Tab(icon: Icon(Icons.dns), text: 'Network Servers'),
                ],
              ),
            ),
          ),
        ),
        body: const TabBarView(
          children: [
            CloudBrowserScreen(),
            NetworkScreen(),
          ],
        ),
      ),
    );
  }
}
