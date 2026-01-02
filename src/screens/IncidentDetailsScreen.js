import React, { useMemo } from "react";
import { View, Text, StyleSheet, TouchableOpacity, ScrollView } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";

export default function IncidentDetailsScreen({ navigation, route }) {
  const incident = route?.params?.incident;

  const data = useMemo(() => {
    // base fallback (so ALL fields exist)
    const fallback = {
      id: "REC-2025-001",
      status: "COMPLETED",
      dateTime: "Dec 15, 2025, 6:40 PM",
      duration: "1m 25s",
      location: "Camarin Rd., Caloocan",
      transcript:
        "Suspect vehicle license plate is Delta X-Ray Charlie 492. Proceeding with caution...",
      markers: [
        { text: "Subject became aggressive", t: "0:30", type: "normal" },
        { text: "EMERGENCY BACKUP REQUESTED", t: "0:45", type: "alert" },
      ],
      tags: ["assault", "traffic-stop", "aggressive-subject", "backup-requested"],
    };

    // merge incoming incident over fallback
    const merged = { ...fallback, ...(incident || {}) };

    // ✅ GUARDS (prevents .map crash)
    merged.markers = Array.isArray(merged.markers) ? merged.markers : [];
    merged.tags = Array.isArray(merged.tags) ? merged.tags : [];

    // if you pass duration like "1:25", show it (optional formatting)
    // keep whatever you pass, fallback already safe
    return merged;
  }, [incident]);

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        <View style={styles.container}>
          {/* Header */}
          <View style={styles.header}>
            <TouchableOpacity
              onPress={() => navigation.goBack()}
              activeOpacity={0.85}
              style={styles.backBtn}
            >
              <Ionicons name="chevron-back" size={18} color="rgba(255,255,255,0.85)" />
            </TouchableOpacity>

            <View style={{ flex: 1 }}>
              <Text style={styles.headerTitle}>Incident Details</Text>
              <Text style={styles.headerSub}>{data.id}</Text>
            </View>
          </View>

          <View style={styles.orangeLine} />

          <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
            {/* Status / Summary */}
            <View style={[styles.card, styles.greenBorder]}>
              <View style={styles.statusPill}>
                <Text style={styles.statusText}>{data.status}</Text>
              </View>

              <View style={{ marginTop: 10 }}>
                <Row icon="calendar-outline" text={data.dateTime} />
                <Row icon="time-outline" text={`Duration : ${data.duration}`} />
                <Row icon="location-outline" text={data.location} />
              </View>
            </View>

            {/* Recording + Snapshot */}
            <View style={styles.twoColRow}>
              <View style={[styles.smallCard, styles.orangeBorder]}>
                <View style={styles.smallHeader}>
                  <View style={styles.smallIconBox}>
                    <Ionicons name="radio-outline" size={16} color="#FFB020" />
                  </View>
                  <Text style={styles.smallTitle}>Recording</Text>
                </View>

                <View style={styles.previewBlack}>
                  <View style={styles.playCircle}>
                    <Ionicons name="play" size={14} color="rgba(255,255,255,0.85)" />
                  </View>

                  <Text style={styles.previewLabel}>Video Playback</Text>
                  <Text style={styles.previewSub}>{data.duration}</Text>
                </View>
              </View>

              <View style={[styles.smallCard, styles.orangeBorder]}>
                <View style={styles.smallHeader}>
                  <View style={styles.smallIconBox}>
                    <Ionicons name="camera-outline" size={16} color="#FFB020" />
                  </View>
                  <Text style={styles.smallTitle}>Snapshot</Text>
                </View>

                <View style={styles.previewGray}>
                  <View style={styles.imageIcon}>
                    <Ionicons name="images-outline" size={18} color="rgba(255,255,255,0.55)" />
                  </View>
                  <Text style={styles.previewLabel}>Images</Text>
                </View>
              </View>
            </View>

            {/* Transcript */}
            <View style={[styles.card, styles.greenBorder]}>
              <View style={styles.sectionHeader}>
                <View style={[styles.sectionIconBox, { backgroundColor: "rgba(61,220,132,0.14)" }]}>
                  <Ionicons name="document-text-outline" size={16} color="#3DDC84" />
                </View>
                <Text style={styles.sectionTitle}>Transcript</Text>
              </View>

              <View style={styles.innerBox}>
                <Text style={styles.innerLabel}>Transcript:</Text>
                <Text style={styles.innerText}>{data.transcript}</Text>
              </View>
            </View>

            {/* Incident Markers */}
            <View style={[styles.card, styles.orangeBorder]}>
              <View style={styles.sectionHeader}>
                <View style={[styles.sectionIconBox, { backgroundColor: "rgba(255,176,32,0.14)" }]}>
                  <Ionicons name="flag-outline" size={16} color="#FFB020" />
                </View>
                <Text style={styles.sectionTitle}>Incident Markers</Text>
              </View>

              <View style={styles.markerList}>
                {data.markers.length === 0 ? (
                  <View style={styles.markerRow}>
                    <Text style={styles.markerEmpty}>No markers recorded</Text>
                  </View>
                ) : (
                  data.markers.map((m, idx) => (
                    <View key={`${m.text}-${idx}`}>
                      <View style={styles.markerRow}>
                        <Text
                          style={[styles.markerText, m.type === "alert" ? styles.markerAlert : null]}
                          numberOfLines={1}
                        >
                          {m.text}
                        </Text>
                        <Text style={styles.markerTime}>{m.t}</Text>
                      </View>
                      {idx !== data.markers.length - 1 && <View style={styles.softDivider} />}
                    </View>
                  ))
                )}
              </View>
            </View>

            {/* Tags */}
            <View style={[styles.card, styles.orangeBorder]}>
              <View style={styles.sectionHeader}>
                <View style={[styles.sectionIconBox, { backgroundColor: "rgba(255,176,32,0.14)" }]}>
                  <Ionicons name="pricetags-outline" size={16} color="#FFB020" />
                </View>
                <Text style={styles.sectionTitle}>Tags</Text>
              </View>

              <View style={styles.tagsRow}>
                {data.tags.length === 0 ? (
                  <Text style={styles.tagsEmpty}>No tags</Text>
                ) : (
                  data.tags.map((t) => (
                    <View key={t} style={styles.tagChip}>
                      <Text style={styles.tagText}>{t}</Text>
                    </View>
                  ))
                )}
              </View>
            </View>

            <View style={{ height: 24 }} />
          </ScrollView>
        </View>
      </SafeAreaView>
    </LinearGradient>
  );
}

function Row({ icon, text }) {
  return (
    <View style={styles.row}>
      <Ionicons name={icon} size={14} color="rgba(255,255,255,0.55)" />
      <Text style={styles.rowText}>{text}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  gradient: { flex: 1 },
  safe: { flex: 1 },
  container: { flex: 1, paddingHorizontal: 14, paddingTop: 6 },

  header: { flexDirection: "row", alignItems: "center", marginBottom: 8 },
  backBtn: {
    width: 34,
    height: 34,
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.18)",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 10,
  },
  headerTitle: { color: "rgba(255,255,255,0.92)", fontSize: 13, fontWeight: "800" },
  headerSub: { color: "rgba(255,255,255,0.45)", fontSize: 11, marginTop: 2 },

  orangeLine: {
    height: 2,
    backgroundColor: "rgba(255,176,32,0.65)",
    borderRadius: 999,
    marginBottom: 12,
  },

  scroll: { paddingBottom: 18 },

  card: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    padding: 12,
    marginBottom: 12,
  },
  greenBorder: { borderColor: "rgba(61,220,132,0.35)" },
  orangeBorder: { borderColor: "rgba(255,176,32,0.30)" },

  statusPill: {
    alignSelf: "flex-start",
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 8,
    backgroundColor: "rgba(46,204,113,0.18)",
    borderWidth: 1,
    borderColor: "rgba(46,204,113,0.35)",
  },
  statusText: { color: "#2ECC71", fontSize: 10, fontWeight: "900" },

  row: { flexDirection: "row", alignItems: "center", marginTop: 8 },
  rowText: { marginLeft: 8, color: "rgba(255,255,255,0.70)", fontSize: 11 },

  twoColRow: { flexDirection: "row", gap: 12, marginBottom: 12 },
  smallCard: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    padding: 12,
  },
  smallHeader: { flexDirection: "row", alignItems: "center", marginBottom: 10 },
  smallIconBox: {
    width: 26,
    height: 26,
    borderRadius: 8,
    backgroundColor: "rgba(255,176,32,0.14)",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 8,
  },
  smallTitle: { color: "rgba(255,255,255,0.88)", fontSize: 12, fontWeight: "800" },

  previewBlack: {
    height: 140,
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.65)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.08)",
    alignItems: "center",
    justifyContent: "center",
  },
  playCircle: {
    width: 34,
    height: 34,
    borderRadius: 999,
    backgroundColor: "rgba(255,255,255,0.12)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 10,
  },
  previewGray: {
    height: 140,
    borderRadius: 10,
    backgroundColor: "rgba(255,255,255,0.10)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.08)",
    alignItems: "center",
    justifyContent: "center",
  },
  imageIcon: {
    width: 38,
    height: 38,
    borderRadius: 12,
    backgroundColor: "rgba(0,0,0,0.12)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 10,
  },
  previewLabel: { color: "rgba(255,255,255,0.85)", fontSize: 11, fontWeight: "700" },
  previewSub: { color: "rgba(255,255,255,0.55)", fontSize: 10, marginTop: 4 },

  sectionHeader: { flexDirection: "row", alignItems: "center", marginBottom: 10 },
  sectionIconBox: {
    width: 26,
    height: 26,
    borderRadius: 8,
    alignItems: "center",
    justifyContent: "center",
    marginRight: 8,
  },
  sectionTitle: { color: "rgba(255,255,255,0.88)", fontSize: 12, fontWeight: "800" },

  innerBox: {
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.22)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.08)",
    padding: 10,
  },
  innerLabel: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginBottom: 6 },
  innerText: { color: "rgba(255,255,255,0.78)", fontSize: 11, lineHeight: 16 },

  markerList: {
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.22)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.08)",
    overflow: "hidden",
  },
  markerRow: {
    paddingHorizontal: 10,
    paddingVertical: 12,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  markerText: { flex: 1, color: "rgba(255,255,255,0.78)", fontSize: 11, marginRight: 10 },
  markerAlert: { color: "rgba(255,80,80,0.95)", fontWeight: "900" },
  markerTime: { color: "rgba(255,255,255,0.45)", fontSize: 11 },
  markerEmpty: { color: "rgba(255,255,255,0.45)", fontSize: 11 },
  softDivider: { height: 1, backgroundColor: "rgba(255,255,255,0.08)" },

  tagsRow: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  tagsEmpty: { color: "rgba(255,255,255,0.45)", fontSize: 11 },
  tagChip: {
    backgroundColor: "rgba(255,122,26,0.20)",
    borderWidth: 1,
    borderColor: "rgba(255,122,26,0.35)",
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
  },
  tagText: { color: "rgba(255,255,255,0.85)", fontSize: 10, fontWeight: "800" },
});
