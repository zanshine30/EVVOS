import React, { useMemo, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
  TextInput,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";

export default function MyIncidentScreen({ navigation }) {
  const [tab, setTab] = useState("All"); // All | Completed | Pending
  const [q, setQ] = useState("");

  // ✅ simulation data only
  const incidents = useMemo(
    () => [
      {
        id: "REC-2025-001",
        status: "COMPLETED",
        age: "30m ago",
        location: "Camarin Rd., Caloocan City",
        duration: "1:25",
        transcript:
          "Suspect vehicle license plate is Delta X-Ray Charlie 492. Proceeding with caution...",
        tags: ["assault", "traffic-stop", "aggressive-subject", "+1 more"],
        alert: true,
      },
      {
        id: "REC-2025-002",
        status: "COMPLETED",
        age: "2h ago",
        location: "Mayville Subdivision Liano Rd., Caloocan City",
        duration: "2:03",
        transcript:
          "Suspect vehicle license plate is Delta X-Ray Charlie 492. Proceeding with caution...",
        tags: ["speeding", "traffic-violation"],
        alert: false,
      },
      {
        id: "REC-2025-003",
        status: "COMPLETED",
        age: "5h ago",
        location: "Bagong Silang, Caloocan City",
        duration: "1:47",
        transcript:
          "Suspect vehicle license plate is Delta X-Ray Charlie 492. Proceeding with caution...",
        tags: ["pedestrian-safety", "warning-issued"],
        alert: false,
      },
    ],
    []
  );

  const filtered = useMemo(() => {
    const query = q.trim().toLowerCase();

    let base =
      tab === "All"
        ? incidents
        : tab === "Completed"
        ? incidents.filter((x) => x.status === "COMPLETED")
        : []; // Pending = empty state (as per figma)

    if (!query) return base;

    return base.filter((x) => {
      const hay = [
        x.id,
        x.location,
        x.duration,
        x.transcript,
        ...(x.tags || []),
      ]
        .join(" ")
        .toLowerCase();
      return hay.includes(query);
    });
  }, [tab, q, incidents]);

  const showEmpty = tab === "Pending" || filtered.length === 0;

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
              activeOpacity={0.8}
              style={styles.backBtn}
            >
              <Ionicons
                name="chevron-back"
                size={18}
                color="rgba(255,255,255,0.85)"
              />
            </TouchableOpacity>

            <View style={styles.headerText}>
              <Text style={styles.headerTitle}>My Incident</Text>
              <Text style={styles.headerSub}>10 recordings</Text>
            </View>
          </View>

          {/* Search */}
          <View style={styles.searchWrap}>
            <Ionicons
              name="search-outline"
              size={16}
              color="rgba(255,255,255,0.45)"
            />
            <TextInput
              value={q}
              onChangeText={setQ}
              placeholder="Search incidents..."
              placeholderTextColor="rgba(255,255,255,0.35)"
              style={styles.searchInput}
            />
          </View>

          {/* Tabs */}
          <View style={styles.tabsRow}>
            <Pill
              label="All"
              active={tab === "All"}
              activeColor="#FF1E1E"
              onPress={() => setTab("All")}
            />
            <Pill
              label="Completed"
              active={tab === "Completed"}
              activeColor="#2ECC71"
              onPress={() => setTab("Completed")}
            />
            <Pill
              label="Pending"
              active={tab === "Pending"}
              activeColor="#FFB020"
              onPress={() => setTab("Pending")}
            />
          </View>

          {/* Orange divider line (like figma) */}
          <View style={styles.orangeLine} />

          {/* List / Empty */}
          <ScrollView
            contentContainerStyle={styles.scroll}
            showsVerticalScrollIndicator={false}
          >
            {showEmpty ? (
              <View style={styles.emptyWrap}>
                <View style={styles.emptyIcon}>
                  <Ionicons
                    name="videocam-outline"
                    size={26}
                    color="rgba(255,255,255,0.35)"
                  />
                </View>
                <Text style={styles.emptyText}>No incident found</Text>
              </View>
            ) : (
              filtered.map((item) => (
                <TouchableOpacity
                  key={item.id}
                  activeOpacity={0.9}
                  style={styles.card}
                  onPress={() => navigation.navigate("IncidentDetails", { incident: item })}
                >
                  {/* top row */}
                  <View style={styles.cardTop}>
                    <View style={styles.statusPill}>
                      <Text style={styles.statusText}>{item.status}</Text>
                    </View>

                    <View style={styles.rightTop}>
                      {item.alert ? (
                        <Ionicons
                          name="warning-outline"
                          size={16}
                          color="rgba(255,176,32,0.9)"
                          style={{ marginRight: 6 }}
                        />
                      ) : null}
                      <Ionicons
                        name="chevron-forward"
                        size={16}
                        color="rgba(255,255,255,0.35)"
                      />
                    </View>
                  </View>

                  <Text style={styles.incidentTitle}>
                    Incident {item.id}
                  </Text>
                  <Text style={styles.ageText}>{item.age}</Text>

                  {/* meta */}
                  <View style={styles.metaRow}>
                    <View style={styles.metaItem}>
                      <Ionicons
                        name="location-outline"
                        size={14}
                        color="rgba(255,255,255,0.45)"
                      />
                      <Text style={styles.metaText}>{item.location}</Text>
                    </View>
                  </View>

                  <View style={styles.metaRow}>
                    <View style={styles.metaItem}>
                      <Ionicons
                        name="time-outline"
                        size={14}
                        color="rgba(255,255,255,0.45)"
                      />
                      <Text style={styles.metaText}>
                        Duration : {item.duration}
                      </Text>
                    </View>
                  </View>

                  {/* transcript preview */}
                  <View style={styles.transBox}>
                    <Text style={styles.transLabel}>Transcript:</Text>
                    <Text style={styles.transText} numberOfLines={2}>
                      {item.transcript}
                    </Text>
                  </View>

                  {/* tags */}
                  <View style={styles.tagsRow}>
                    {item.tags.slice(0, 4).map((t) => (
                      <View key={t} style={styles.tag}>
                        <Text style={styles.tagText}>{t}</Text>
                      </View>
                    ))}
                  </View>
                </TouchableOpacity>
              ))
            )}

            <View style={{ height: 24 }} />
          </ScrollView>
        </View>
      </SafeAreaView>
    </LinearGradient>
  );
}

function Pill({ label, active, activeColor, onPress }) {
  return (
    <TouchableOpacity
      onPress={onPress}
      activeOpacity={0.85}
      style={[
        styles.pill,
        active ? { backgroundColor: activeColor, borderColor: activeColor } : null,
      ]}
    >
      <Text style={[styles.pillText, active ? styles.pillTextActive : null]}>
        {label}
      </Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  gradient: { flex: 1 },
  safe: { flex: 1 },
  container: { flex: 1, paddingHorizontal: 14, paddingTop: 6 },

  header: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
  },
  backBtn: {
    width: 34,
    height: 34,
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.18)",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 10,
  },
  headerText: { flex: 1 },
  headerTitle: {
    color: "rgba(255,255,255,0.92)",
    fontSize: 13,
    fontWeight: "700",
  },
  headerSub: {
    color: "rgba(255,255,255,0.45)",
    fontSize: 11,
    marginTop: 2,
  },

  searchWrap: {
    height: 40,
    borderRadius: 10,
    backgroundColor: "rgba(255,255,255,0.06)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    paddingHorizontal: 12,
    flexDirection: "row",
    alignItems: "center",
  },
  searchInput: {
    flex: 1,
    marginLeft: 8,
    color: "rgba(255,255,255,0.90)",
    fontSize: 12,
  },

  tabsRow: {
    flexDirection: "row",
    gap: 10,
    marginTop: 10,
    marginBottom: 10,
  },
  pill: {
    paddingVertical: 8,
    paddingHorizontal: 16,
    borderRadius: 999,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  pillText: { color: "rgba(255,255,255,0.70)", fontSize: 11, fontWeight: "700" },
  pillTextActive: { color: "white" },

  orangeLine: {
    height: 2,
    backgroundColor: "rgba(255,176,32,0.65)",
    borderRadius: 999,
    marginBottom: 10,
  },

  scroll: { paddingBottom: 18 },

  card: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,176,32,0.30)",
    padding: 12,
    marginBottom: 12,
  },
  cardTop: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 8,
  },
  statusPill: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 8,
    backgroundColor: "rgba(46,204,113,0.18)",
    borderWidth: 1,
    borderColor: "rgba(46,204,113,0.35)",
  },
  statusText: { color: "#2ECC71", fontSize: 10, fontWeight: "800" },
  rightTop: { flexDirection: "row", alignItems: "center" },

  incidentTitle: {
    color: "rgba(255,255,255,0.92)",
    fontSize: 13,
    fontWeight: "800",
  },
  ageText: {
    color: "rgba(255,255,255,0.45)",
    fontSize: 11,
    marginTop: 2,
    marginBottom: 8,
  },

  metaRow: { flexDirection: "row", alignItems: "center", marginBottom: 6 },
  metaItem: { flexDirection: "row", alignItems: "center", flex: 1 },
  metaText: {
    marginLeft: 6,
    color: "rgba(255,255,255,0.55)",
    fontSize: 11,
    flex: 1,
  },

  transBox: {
    backgroundColor: "rgba(0,0,0,0.22)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.08)",
    padding: 10,
    marginTop: 6,
  },
  transLabel: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginBottom: 6 },
  transText: { color: "rgba(255,255,255,0.78)", fontSize: 11, lineHeight: 16 },

  tagsRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginTop: 10,
  },
  tag: {
    backgroundColor: "rgba(255,122,26,0.20)",
    borderWidth: 1,
    borderColor: "rgba(255,122,26,0.35)",
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
  },
  tagText: { color: "rgba(255,255,255,0.85)", fontSize: 10, fontWeight: "700" },

  emptyWrap: {
    alignItems: "center",
    justifyContent: "center",
    paddingTop: 90,
  },
  emptyIcon: {
    width: 52,
    height: 52,
    borderRadius: 14,
    backgroundColor: "rgba(0,0,0,0.18)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 10,
  },
  emptyText: {
    color: "rgba(255,255,255,0.45)",
    fontSize: 12,
    fontWeight: "600",
  },
});
