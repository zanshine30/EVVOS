import React, { useMemo, useState } from "react";
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, TextInput, Alert } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { useAuth } from "../context/AuthContext";
import supabase from "../lib/supabase";

export default function IncidentDetailsScreen({ navigation, route }) {
  const incident = route?.params?.incident;
  const { displayName, user } = useAuth();

  const officerName = `Officer ${displayName}`;

  const [driverName, setDriverName] = useState("");
  const [plateNumber, setPlateNumber] = useState("");
  const [location, setLocation] = useState("");
  const [notes, setNotes] = useState("");
  const [selectedViolations, setSelectedViolations] = useState([]);
  const [submitting, setSubmitting] = useState(false);

  const commonViolations = useMemo(
    () => [
      "Speeding",
      "No Helmet",
      "Driving w/o driver's license",
      "Running Red Light",
      "Reckless Driving",
      "DUI Suspicion",
      "Expired Registration",
      "No Insurance",
      "Illegal Parking",
      "Using Mobile Phone",
    ],
    []
  );

  const [selectedList, setSelectedList] = useState([]);
  const [customViolation, setCustomViolation] = useState("");
  const [customList, setCustomList] = useState([]);

  const isSelected = (label) => selectedList.includes(label);

  const addSelected = (label) => {
    setSelectedList((prev) => {
      if (prev.includes(label)) return prev;
      return [...prev, label];
    });
  };

  const removeSelected = (label) => {
    setSelectedList((prev) => prev.filter((x) => x !== label));
  };

  const toggleViolation = (label) => {
    if (isSelected(label)) removeSelected(label);
    else addSelected(label);
  };

  const addCustomViolation = () => {
    const v = customViolation.trim();
    if (!v) return;

    const exists =
      selectedList.some((x) => x.toLowerCase() === v.toLowerCase()) ||
      customList.some((x) => x.toLowerCase() === v.toLowerCase()) ||
      commonViolations.some((x) => x.toLowerCase() === v.toLowerCase());

    if (exists) {
      setCustomViolation("");
      return;
    }

    setCustomList((prev) => [...prev, v]);
    setSelectedList((prev) => [...prev, v]);
    setCustomViolation("");
  };

  const data = useMemo(() => {
   
    const fallback = {
      id: "REC-2025-001",
      incident_id: "INCIDENT20250001",
      status: "COMPLETED",
      dateTime: "Dec 15, 2025, 6:40 PM",
      duration: "1m 25s",
      location: "Camarin Rd., Caloocan",
      transcript:
        "Suspect vehicle license plate is Delta X-Ray Charlie 492. Proceeding with caution...",
      violations: ["Speeding", "No Helmet"],
      tags: ["assault", "traffic-stop", "aggressive-subject", "backup-requested"],
    };

    const merged = { ...fallback, ...(incident || {}) };

    // Set dateTime from date_time if available
    if (incident?.date_time) {
      merged.dateTime = new Date(incident.date_time).toLocaleString();
    }

    merged.violations = Array.isArray(merged.violations) ? merged.violations : [];
    merged.tags = Array.isArray(merged.tags) ? merged.tags : [];

    // Pre-fill state if pending
    if (merged.status === 'PENDING' && incident) {
      setDriverName(incident.driver_name || "");
      setPlateNumber(incident.plate_number || "");
      setLocation(incident.location || "");
      setNotes(incident.notes || "");
      setSelectedViolations(merged.violations);
      setSelectedList(merged.violations);
    }

    return merged;
  }, [incident]);

  const handleSubmit = async () => {
    if (!driverName.trim() || !plateNumber.trim()) {
      Alert.alert("Error", "Driver name and plate number are required.");
      return;
    }

    // Show confirmation for PENDING incidents being updated to COMPLETED
    if (isPending) {
      Alert.alert(
        "Update Incident",
        "Are you sure you want to finalize and submit this pending incident?",
        [
          {
            text: "Cancel",
            style: "cancel",
          },
          {
            text: "Submit",
            style: "default",
            onPress: () => submitIncident(),
          },
        ]
      );
      return;
    }

    submitIncident();
  };

  const submitIncident = async () => {
    setSubmitting(true);

    const incidentData = {
      incident_id: data.incident_id,
      status: "COMPLETED",
      location,
      driver_name: driverName,
      plate_number: plateNumber,
      violations: selectedList,
      notes,
      transcript: data.transcript,
      duration: data.duration,
      date_time: incident?.date_time || new Date().toISOString(),
      officer_id: user.id,
      display_name: officerName,
      tags: data.tags,
    };

    try {
      await supabase.auth.refreshSession();

      const { data: result, error } = await supabase.functions.invoke('insert-incident', {
        body: incidentData,
      });

      if (error) {
        console.error("Error updating incident:", error);
        Alert.alert("Error", "Failed to update incident. Please try again.");
      } else if (result?.success) {
        Alert.alert("Success", "Incident updated successfully.", [
          {
            text: "OK",
            onPress: () => navigation.goBack(),
          },
        ]);
      } else {
        Alert.alert("Error", "Failed to update incident. Please try again.");
      }
    } catch (err) {
      console.error("Unexpected error:", err);
      Alert.alert("Error", "Failed to update incident. Please try again.");
    } finally {
      setSubmitting(false);
    }
  };

  const isPending = data.status === 'PENDING';

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        <View style={styles.container}>
      
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
              <Text style={styles.headerSub}>{data.incident_id || data.id}</Text>
            </View>
          </View>

          <View style={styles.orangeLine} />

          <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
           
            <View style={[styles.card, styles.greenBorder]}>
              <View style={[styles.statusPill, data.status === 'PENDING' ? styles.pendingPill : styles.completedPill]}>
                <Text style={[styles.statusText, data.status === 'PENDING' ? styles.pendingText : styles.completedText]}>{data.status}</Text>
              </View>

              <View style={{ marginTop: 10 }}>
                <Row icon="calendar-outline" text={data.dateTime} />
                <Row icon="time-outline" text={`Duration : ${data.duration}`} />
                <Row icon="location-outline" text={data.location} />
              </View>
            </View>

           
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

            <View style={[styles.card, styles.orangeBorder]}>
              <View style={styles.sectionHeader}>
                <View style={[styles.sectionIconBox, { backgroundColor: "rgba(255,176,32,0.14)" }]}>
                  <Ionicons name="person-outline" size={16} color="#FFB020" />
                </View>
                <Text style={styles.sectionTitle}>Driver Details</Text>
              </View>

              <View style={styles.innerBox}>
                {isPending ? (
                  <>
                    <Text style={styles.innerLabel}>Driver Name:</Text>
                    <TextInput
                      value={driverName}
                      onChangeText={setDriverName}
                      placeholder="Enter driver name"
                      placeholderTextColor="rgba(255,255,255,0.5)"
                      style={styles.input}
                    />
                    <Text style={styles.innerLabel}>Plate Number:</Text>
                    <TextInput
                      value={plateNumber}
                      onChangeText={setPlateNumber}
                      placeholder="Enter plate number"
                      placeholderTextColor="rgba(255,255,255,0.5)"
                      style={styles.input}
                    />
                    <Text style={styles.innerLabel}>Location:</Text>
                    <TextInput
                      value={location}
                      onChangeText={setLocation}
                      placeholder="Enter location"
                      placeholderTextColor="rgba(255,255,255,0.5)"
                      style={styles.input}
                    />
                    <Text style={styles.innerLabel}>Notes:</Text>
                    <TextInput
                      value={notes}
                      onChangeText={setNotes}
                      placeholder="Enter notes"
                      placeholderTextColor="rgba(255,255,255,0.5)"
                      style={[styles.input, styles.notesInput]}
                      multiline
                    />
                  </>
                ) : (
                  <>
                    <Text style={styles.innerLabel}>Driver Name: {data.driver_name || "N/A"}</Text>
                    <Text style={styles.innerLabel}>Plate Number: {data.plate_number || "N/A"}</Text>
                    <Text style={styles.innerLabel}>Notes: {data.notes || "N/A"}</Text>
                  </>
                )}
              </View>
            </View>

            <View style={[styles.card, styles.orangeBorder]}>
              <View style={styles.sectionHeader}>
                <View style={[styles.sectionIconBox, { backgroundColor: "rgba(255,176,32,0.14)" }]}>
                  <Ionicons name="flag-outline" size={16} color="#FFB020" />
                </View>
                <Text style={styles.sectionTitle}>Violations</Text>
              </View>

              {isPending ? (
                <>
                  {selectedList.length === 0 ? (
                    <View style={styles.ghostInput}>
                      <Text style={styles.ghostText}>No violations added yet</Text>
                    </View>
                  ) : (
                    <View style={styles.selectedListWrap}>
                      {selectedList.map((v, idx) => (
                        <View key={`${v}-${idx}`} style={styles.selectedRow}>
                          <Text style={styles.selectedRowText}>
                            {idx + 1}. {v}
                          </Text>

                          <TouchableOpacity
                            onPress={() => removeSelected(v)}
                            activeOpacity={0.8}
                            style={styles.removeBtn}
                          >
                            <Ionicons
                              name="close"
                              size={14}
                              color="rgba(255,255,255,0.70)"
                            />
                          </TouchableOpacity>
                        </View>
                      ))}
                    </View>
                  )}

                  <Text style={[styles.label, { marginTop: 12 }]}>
                    Common Violations:
                  </Text>

                  <View style={styles.commonGrid}>
                    {commonViolations.map((v) => {
                      const on = isSelected(v);
                      return (
                        <TouchableOpacity
                          key={v}
                          activeOpacity={0.85}
                          onPress={() => toggleViolation(v)}
                          style={[styles.commonBtn, on ? styles.commonBtnOn : null]}
                        >
                          <Text
                            style={[
                              styles.commonBtnText,
                              on ? styles.commonBtnTextOn : null,
                            ]}
                          >
                            {v}
                          </Text>
                        </TouchableOpacity>
                      );
                    })}
                  </View>

                  <Text style={[styles.label, { marginTop: 12 }]}>
                    Add Custom Violation
                  </Text>

                  <View style={styles.customRow}>
                    <View style={[styles.inputWrap, { flex: 1, height: 42 }]}>
                      <TextInput
                        value={customViolation}
                        onChangeText={setCustomViolation}
                        placeholder="Enter other violation"
                        placeholderTextColor="rgba(255,255,255,0.35)"
                        style={[styles.input, { height: 42 }]}
                        returnKeyType="done"
                        onSubmitEditing={addCustomViolation}
                      />
                    </View>

                    <TouchableOpacity
                      style={styles.addBtn}
                      activeOpacity={0.9}
                      onPress={addCustomViolation}
                    >
                      <Text style={styles.addBtnText}>Add</Text>
                    </TouchableOpacity>
                  </View>
                </>
              ) : (
                <View style={styles.markerList}>
                  {data.violations.length === 0 ? (
                    <View style={styles.markerRow}>
                      <Text style={styles.markerEmpty}>No violations recorded</Text>
                    </View>
                  ) : (
                    data.violations.map((v, idx) => (
                      <View key={`${v}-${idx}`}>
                        <View style={styles.markerRow}>
                          <Text style={styles.markerText} numberOfLines={1}>
                            {v}
                          </Text>
                        </View>
                        {idx !== data.violations.length - 1 && <View style={styles.softDivider} />}
                      </View>
                    ))
                  )}
                </View>
              )}
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

          {isPending && (
            <View style={styles.bottomBar}>
              <TouchableOpacity
                onPress={handleSubmit}
                disabled={submitting}
                style={[styles.finalizeBtn, submitting && styles.finalizeBtnDisabled]}
              >
                <Text style={styles.finalizeText}>
                  {submitting ? "Updating..." : "Complete Incident"}
                </Text>
              </TouchableOpacity>
            </View>
          )}
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
    borderWidth: 1,
  },
  completedPill: {
    backgroundColor: "rgba(46,204,113,0.18)",
    borderColor: "rgba(46,204,113,0.35)",
  },
  pendingPill: {
    backgroundColor: "rgba(255,176,32,0.18)",
    borderColor: "rgba(255,176,32,0.35)",
  },
  statusText: { fontSize: 10, fontWeight: "900" },
  completedText: { color: "#2ECC71" },
  pendingText: { color: "#FFB020" },

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
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 12,
    backgroundColor: "rgba(255,176,32,0.14)",
    borderWidth: 1,
    borderColor: "rgba(255,176,32,0.30)",
  },
  tagText: { color: "#FFB020", fontSize: 10, fontWeight: "700" },
  input: { color: "rgba(255,255,255,0.90)", fontSize: 12, borderBottomWidth: 1, borderBottomColor: "rgba(255,255,255,0.3)", paddingVertical: 4 },
  notesInput: { minHeight: 60, textAlignVertical: "top" },

  label: { color: "rgba(255,255,255,0.55)", fontSize: 11 },

  inputWrap: {
    backgroundColor: "rgba(255,255,255,0.06)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    paddingHorizontal: 12,
    height: 44,
    justifyContent: "center",
  },

  ghostInput: {
    height: 40,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    backgroundColor: "rgba(255,255,255,0.05)",
    justifyContent: "center",
    paddingHorizontal: 12,
  },
  ghostText: { color: "rgba(255,255,255,0.40)", fontSize: 11 },

  selectedListWrap: { gap: 10 },
  selectedRow: {
    height: 40,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,80,80,0.35)",
    backgroundColor: "rgba(255,255,255,0.04)",
    paddingHorizontal: 12,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  selectedRowText: { color: "rgba(255,255,255,0.80)", fontSize: 11 },
  removeBtn: {
    width: 26,
    height: 26,
    borderRadius: 8,
    backgroundColor: "rgba(255,255,255,0.10)",
    alignItems: "center",
    justifyContent: "center",
  },

  commonGrid: {
    flexDirection: "row",
    flexWrap: "wrap",
    justifyContent: "space-between",
    marginTop: 10,
    rowGap: 10,
  },
  commonBtn: {
    width: "48%",
    height: 36,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    backgroundColor: "rgba(255,255,255,0.04)",
    paddingHorizontal: 10,
    justifyContent: "center",
  },
  commonBtnOn: {
    borderColor: "rgba(255,80,80,0.45)",
    backgroundColor: "rgba(255,80,80,0.16)",
  },
  commonBtnText: { color: "rgba(255,255,255,0.70)", fontSize: 11 },
  commonBtnTextOn: { color: "rgba(255,255,255,0.92)", fontWeight: "700" },

  customRow: {
    flexDirection: "row",
    alignItems: "center",
    marginTop: 10,
    gap: 10,
  },
  addBtn: {
    height: 42,
    paddingHorizontal: 16,
    borderRadius: 10,
    backgroundColor: "#FF7A1A",
    alignItems: "center",
    justifyContent: "center",
  },
  addBtnText: { color: "white", fontSize: 12, fontWeight: "700" },

  bottomBar: {
    paddingHorizontal: 16,
    paddingBottom: 14,
    paddingTop: 8,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderTopWidth: 1,
    borderTopColor: "rgba(255,255,255,0.08)",
  },
  finalizeBtn: {
    backgroundColor: "#1E9E5A",
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
    justifyContent: "center",
  },
  finalizeText: { color: "white", fontSize: 15, fontWeight: "700" },
  finalizeBtnDisabled: { backgroundColor: "rgba(30,158,90,0.5)" },
});
