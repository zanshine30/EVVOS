import React from "react";
import { View, Text, StyleSheet, TouchableOpacity, ScrollView } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";

export default function HomeScreen({ navigation }) {
  const officerName = "Officer Marcus Rodriguez";
  const badge = "Badge #4521";
  const location = "Camarin Rd.";
  const time = "6:40 pm";

  const handleLogout = () => {
    navigation.reset({ index: 0, routes: [{ name: "Login" }] });
  };

  const handleStartRecording = () => {
    navigation.navigate("Recording");
  };

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        <ScrollView
          contentContainerStyle={styles.scroll}
          showsVerticalScrollIndicator={false}
          alwaysBounceVertical={false}
        >
          {/* Officer Card */}
          <View style={styles.officerCard}>
            <View style={styles.officerTopRow}>
              <View style={styles.officerLeft}>
                <View style={styles.officerIcon}>
                  <Ionicons name="person" size={18} color="white" />
                </View>

                <View>
                  <Text style={styles.officerName}>{officerName}</Text>
                  <Text style={styles.officerBadge}>{badge}</Text>
                </View>
              </View>

              <TouchableOpacity onPress={handleLogout} activeOpacity={0.75}>
                <Ionicons name="log-out-outline" size={20} color="#FF4A4A" />
              </TouchableOpacity>
            </View>

            <View style={styles.statusRow}>
              <View style={styles.statusItem}>
                <View style={styles.dotGreen} />
                <Text style={styles.statusText}>On Duty</Text>
              </View>

              <View style={styles.statusItem}>
                <Ionicons name="location-outline" size={14} color="#FF4A4A" />
                <Text style={styles.statusText}>{location}</Text>
              </View>

              <View style={styles.statusItem}>
                <Ionicons name="time-outline" size={14} color="rgba(255,255,255,0.7)" />
                <Text style={styles.statusText}>{time}</Text>
              </View>
            </View>
          </View>

          {/* Stats */}
          <View style={styles.statsRow}>
            <View style={[styles.statCard, styles.statGreenBorder]}>
              <Text style={styles.statValue}>10</Text>
              <Text style={styles.statLabel}>Today's Cases</Text>
            </View>

            <View style={[styles.statCard, styles.statYellowBorder]}>
              <Text style={styles.statValue}>3h 20m</Text>
              <Text style={styles.statLabel}>Recording Time</Text>
            </View>

            <View style={[styles.statCard, styles.statRedBorder]}>
              <Text style={styles.statValue}>5</Text>
              <Text style={styles.statLabel}>Emergencies</Text>
            </View>
          </View>

          {/* Start Recording (bigger like Figma) */}
          <TouchableOpacity
            style={styles.recordCard}
            activeOpacity={0.9}
            onPress={handleStartRecording}
          >
            <View style={styles.recordCircle}>
              <Ionicons name="videocam-outline" size={28} color="#FF1E1E" />
            </View>

            <View style={{ flex: 1 }}>
              <Text style={styles.recordTitle}>Start Recording</Text>
              <Text style={styles.recordSub}>Tap or say "Start Recording"</Text>
            </View>
          </TouchableOpacity>

          {/* My Incident */}
          <TouchableOpacity style={styles.myIncidentCard} activeOpacity={0.85} onPress={() => navigation.navigate("MyIncident")}>
            <View style={styles.myIncidentIconBox}>
              <Ionicons
                name="document-text-outline"
                size={18}
                color="rgba(255,255,255,0.85)"
              />
            </View>
            <Text style={styles.myIncidentTitle}>My Incident</Text>
            <Text style={styles.myIncidentSub}>View History</Text>
          </TouchableOpacity>

          {/* Recent Activity */}
          <View style={styles.activityCard}>
            <View style={styles.activityHeader}>
              <Ionicons
                name="hourglass-outline"
                size={18}
                color="rgba(255,255,255,0.75)"
              />
              <Text style={styles.activityTitle}>Recent Activity</Text>
            </View>

            <View style={styles.line} />

            {/* Item 1 */}
            <View style={styles.activityItem}>
              <View style={[styles.activityDot, styles.dotSuccess]}>
                <Ionicons name="checkmark" size={14} color="white" />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.activityMain}>Incident #23 completed</Text>
                <Text style={styles.activitySub}>
                  Traffic violation • 36 mins ago
                </Text>
              </View>
            </View>

            <View style={styles.itemDivider} />

            {/* Item 2 */}
            <View style={styles.activityItem}>
              <View style={[styles.activityDot, styles.dotWarn]}>
                <Ionicons name="alert" size={14} color="white" />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.activityMain}>Backup requested</Text>
                <Text style={styles.activitySub}>Camarin Rd. • 1 hour ago</Text>
              </View>
            </View>

            <View style={styles.itemDivider} />

            {/* Item 3 */}
            <View style={styles.activityItem}>
              <View style={[styles.activityDot, styles.dotDanger]}>
                <Ionicons name="warning" size={14} color="white" />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.activityMain}>Emergency alert sent</Text>
                <Text style={styles.activitySub}>Highway patrol • 4 hours ago</Text>
              </View>
            </View>
          </View>
        </ScrollView>
      </SafeAreaView>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  gradient: { flex: 1 },
  safe: { flex: 1 },

  // ✅ makes the whole screen scrollable and fills the screen to avoid dead space feel
  scroll: {
    flexGrow: 1,
    paddingHorizontal: 18,
    paddingTop: 6,
    paddingBottom: 26,
  },

  officerCard: {
    backgroundColor: "rgba(0,0,0,0.20)",
    borderRadius: 12,
    padding: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  officerTopRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  officerLeft: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  officerIcon: {
    width: 34,
    height: 34,
    borderRadius: 10,
    backgroundColor: "#1E7AE6",
    alignItems: "center",
    justifyContent: "center",
  },
  officerName: { color: "white", fontSize: 14, fontWeight: "600" },
  officerBadge: { color: "rgba(255,255,255,0.6)", fontSize: 11, marginTop: 2 },

  statusRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginTop: 10,
  },
  statusItem: { flexDirection: "row", alignItems: "center", gap: 6 },
  dotGreen: {
    width: 8,
    height: 8,
    borderRadius: 999,
    backgroundColor: "#3DDC84",
  },
  statusText: { color: "rgba(255,255,255,0.65)", fontSize: 11 },

  statsRow: { flexDirection: "row", gap: 10, marginTop: 12 },
  statCard: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    paddingVertical: 12,
    alignItems: "center",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  statGreenBorder: { borderColor: "rgba(61,220,132,0.45)" },
  statRedBorder: { borderColor: "rgba(255,80,80,0.40)" },
  statYellowBorder: { borderColor: "rgba(248, 187, 5, 0.4)" },
  statValue: { color: "white", fontSize: 16, fontWeight: "700" },
  statLabel: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginTop: 6 },

  // ✅ Bigger Start Recording card (Figma-like)
  recordCard: {
    marginTop: 30,
    backgroundColor: "#FF1E1E",
    borderRadius: 16,
    paddingHorizontal: 18,
    paddingVertical: 22,
    flexDirection: "row",
    alignItems: "center",
    minHeight: 150,
  },
  recordCircle: {
    width: 58,
    height: 58,
    borderRadius: 999,
    backgroundColor: "white",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 14,
  },
  recordTitle: { color: "white", fontSize: 18, fontWeight: "700" },
  recordSub: { color: "rgba(255,255,255,0.85)", fontSize: 11, marginTop: 6 },

  myIncidentCard: {
    marginTop: 30,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    paddingVertical: 18,
    alignItems: "center",
    borderWidth: 1,
    borderColor: "#fab871",
  },
  myIncidentIconBox: {
    width: 34,
    height: 34,
    borderRadius: 10,
    backgroundColor: "rgba(255,255,255,0.08)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 8,
  },
  myIncidentTitle: { color: "white", fontSize: 14, fontWeight: "600" },
  myIncidentSub: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginTop: 3 },

  activityCard: {
    marginTop: 20,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  activityHeader: { flexDirection: "row", alignItems: "center", gap: 8 },
  activityTitle: { color: "white", fontSize: 14, fontWeight: "600" },
  line: {
    height: 1,
    backgroundColor: "rgba(255,255,255,0.10)",
    marginVertical: 12,
  },

  activityItem: { flexDirection: "row", gap: 10, alignItems: "center" },
  activityDot: {
    width: 24,
    height: 24,
    borderRadius: 9,
    alignItems: "center",
    justifyContent: "center",
  },
  dotSuccess: { backgroundColor: "#2ECC71" },
  dotWarn: { backgroundColor: "#F39C12" },
  dotDanger: { backgroundColor: "#E74C3C" },

  activityMain: { color: "white", fontSize: 13, fontWeight: "600" },
  activitySub: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginTop: 2 },

  itemDivider: {
    height: 1,
    backgroundColor: "rgba(255,255,255,0.08)",
    marginVertical: 10,
  },
});
