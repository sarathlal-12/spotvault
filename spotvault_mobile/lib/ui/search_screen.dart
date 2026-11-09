import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final ctrl = TextEditingController();

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = store.search(ctrl.text);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: ctrl,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Songs, artists or albums',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(ctrl.clear),
                      ),
                filled: true,
                fillColor: Colors.white,
                hintStyle: const TextStyle(color: Colors.black54),
                prefixIconColor: Colors.black87,
                suffixIconColor: Colors.black87,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              ),
              style: const TextStyle(color: Colors.black),
            ),
          ),
          Expanded(
            child: ctrl.text.isEmpty
                ? const Center(child: Text('Search your synced music', style: TextStyle(color: kMuted)))
                : results.isEmpty
                    ? const Center(child: Text('No matches', style: TextStyle(color: kMuted)))
                    : ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (_, i) => TrackTile(track: results[i], list: results, index: i),
                      ),
          ),
        ],
      ),
    );
  }
}
