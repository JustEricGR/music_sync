import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../themes/app_themes.dart';
import '../themes/theme_provider.dart';

class DynamicPlayer extends StatefulWidget {
  const DynamicPlayer({Key? key}) : super(key: key);

  @override
  State<DynamicPlayer> createState() => _DynamicPlayerState();
}

class _DynamicPlayerState extends State<DynamicPlayer> {
  SongMood _currentMood = SongMood.chill;
  bool _isPlaying = false;

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final currentTheme = themeProvider.currentTheme;
    
    // Extragem culorile playerului bazate pe starea curentă a melodiei
    final playerColors = currentTheme.playerMoods[_currentMood] ?? currentTheme.playerMoods[SongMood.chill]!;

    return Column(
      children: [
        // --- TEME SELECTOR (Doar pentru test în UI) ---
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: appThemes.values.map((theme) {
            final isSelected = currentTheme.id == theme.id;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSelected ? currentTheme.accentColor : currentTheme.cardBackground,
                  foregroundColor: isSelected ? Colors.white : currentTheme.textColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                onPressed: () => themeProvider.switchTheme(theme.id),
                child: Text(theme.name),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 30),

        // --- PLAYERUL ANIMAT (Magia vizuală) ---
        AnimatedContainer(
          duration: const Duration(milliseconds: 800), // Schimbare fluidă a gradientului ca un val
          curve: Curves.easeInOut,
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: playerColors.gradientColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 20,
                offset: const Offset(0, 10),
              )
            ],
          ),
          child: Column(
            children: [
              // Coperta Album implicită / Blurată
              Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Center(child: Icon(Icons.music_note, size: 60, color: Colors.white70)),
              ),
              const SizedBox(height: 30),
              Text(
                "Mediterranean Sunset",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: playerColors.textColor),
              ),
              const SizedBox(height: 5),
              Text(
                "Regiunea: ${currentTheme.name}",
                style: TextStyle(fontSize: 14, color: playerColors.textColor.withOpacity(0.7)),
              ),
              const SizedBox(height: 30),
              
              // Progres Timeline
              Row(
                children: [
                  Text("1:24", style: TextStyle(color: playerColors.textColor, fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: 0.35,
                      activeColor: playerColors.accentColor,
                      inactiveColor: playerColors.textColor.withOpacity(0.2),
                      onChanged: (v) {},
                    ),
                  ),
                  Text("3:45", style: TextStyle(color: playerColors.textColor, fontSize: 12)),
                ],
              ),
              
              // Controale
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous, size: 36),
                    color: playerColors.textColor,
                    onPressed: () {},
                  ),
                  const SizedBox(width: 20),
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: Colors.white,
                    child: IconButton(
                      icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 30),
                      color: const Color(0xFF1A2530),
                      onPressed: () => setState(() => _isPlaying = !_isPlaying),
                    ),
                  ),
                  const SizedBox(width: 20),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 36),
                    color: playerColors.textColor,
                    onPressed: () {},
                  ),
                ],
              ),
              
              // Simulator de Stare Melodie
              const Divider(color: Colors.white12, height: 40),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: SongMood.values.map((mood) {
                  return ChoiceChip(
                    label: Text(mood.name.toUpperCase(), style: const TextStyle(fontSize: 10)),
                    selected: _currentMood == mood,
                    onSelected: (selected) {
                      if (selected) setState(() => _currentMood = mood);
                    },
                  );
                }).toList(),
              )
            ],
          ),
        ),
      ],
    );
  }
}