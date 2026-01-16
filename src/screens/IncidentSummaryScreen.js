import React, { useMemo, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TextInput,
  TouchableOpacity,
  KeyboardAvoidingView,
  Platform,
  Modal,
  Pressable,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { useAuth } from "../context/AuthContext";

export default function IncidentSummaryScreen({ navigation }) {
  const { displayName, badge } = useAuth();
  
  const officerName = `Officer ${displayName}`;
  const badgeText = badge ? `#${badge}` : '';
  const duration = "3m 42s";
  const dateTime = new Date().toLocaleString();

  const [driverName, setDriverName] = useState("");
  const [plateNumber, setPlateNumber] = useState("");
  const [location, setLocation] = useState("Camarin rd. Caloocan City");

  const [closeOpen, setCloseOpen] = useState(false);

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
  const [notes, setNotes] = useState("");

  const transcript =
    "Suspect vehicle license plate is Delta X-Ray Charlie 492. Proceeding with caution...";

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

  const handleFinalize = () => {
    console.log("Finalize submission (simulation)", {
      driverName,
      plateNumber,
      location,
      violations: selectedList,
      notes,
    });

    navigation.popToTop();
  };

  const handleClose = () => setCloseOpen(true);

  const confirmClose = () => {
    setCloseOpen(false);
    navigation.navigate("Home");
  };

  const noViolations = selectedList.length === 0;

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        <KeyboardAvoidingView
          style={styles.flex}
          behavior={Platform.OS === "ios" ? "padding" : undefined}
        >
          <View style={styles.container}>
          
            <View style={styles.header}>
              <View style={styles.headerLeft}>
                <View style={styles.headerIconBox}>
                  <Ionicons
                    name="document-text-outline"
                    size={16}
                    color="#FFB020"
                  />
                </View>
                <View>
                  <Text style={styles.headerTitle}>Incident Summary</Text>
                  <Text style={styles.headerSub}>Report completion</Text>
                </View>
              </View>

              <TouchableOpacity
                onPress={handleClose}
                activeOpacity={0.8}
                style={styles.closeBtn}
              >
                <Ionicons
                  name="close"
                  size={18}
                  color="rgba(255,255,255,0.75)"
                />
              </TouchableOpacity>
            </View>

            <View style={styles.headerDivider} />

            <ScrollView
              contentContainerStyle={styles.scroll}
              showsVerticalScrollIndicator={false}
              keyboardShouldPersistTaps="handled"
            >
          
              <View style={[styles.card, styles.recordCard]}>
                <View style={styles.recordHeader}>
                  <Ionicons name="checkmark-circle" size={16} color="#3DDC84" />
                  <Text style={styles.recordTitle}>Recording Completed</Text>
                </View>

                <View style={styles.recordRows}>
                  <RecordRow label="Duration:" value={duration} />
                  <RecordRow label="Date & Time:" value={dateTime} />
                  <RecordRow label="Officer:" value={officerName} />
                  <RecordRow label="Badge:" value={badgeText} />
                </View>
              </View>

              
              <View style={[styles.card, styles.cardOrangeBorder]}>
                <View style={styles.sectionHeader}>
                  <Ionicons name="person-outline" size={16} color="#FFB020" />
                  <Text style={styles.sectionTitle}>Driver Details</Text>
                </View>

                <Text style={styles.inputLabel}>Driver's Details *</Text>
                <View style={styles.inputWrap}>
                  <TextInput
                    value={driverName}
                    onChangeText={setDriverName}
                    placeholder="Enter driver's full name"
                    placeholderTextColor="rgba(255,255,255,0.35)"
                    style={styles.input}
                  />
                </View>

                <Text style={[styles.inputLabel, { marginTop: 10 }]}>
                  Plate Number *
                </Text>
                <View style={styles.inputWrap}>
                  <TextInput
                    value={plateNumber}
                    onChangeText={setPlateNumber}
                    placeholder="e.g. ABC 1234"
                    placeholderTextColor="rgba(255,255,255,0.35)"
                    style={styles.input}
                    autoCapitalize="characters"
                  />
                </View>

                <Text style={[styles.inputLabel, { marginTop: 10 }]}>
                  Location
                </Text>
                <View style={styles.inputWrap}>
                  <View style={styles.locationRow}>
                    <Ionicons
                      name="location-outline"
                      size={16}
                      color="rgba(255,255,255,0.55)"
                    />
                    <TextInput
                      value={location}
                      onChangeText={setLocation}
                      placeholder="Enter location"
                      placeholderTextColor="rgba(255,255,255,0.35)"
                      style={[styles.input, { paddingLeft: 10, flex: 1 }]}
                    />
                  </View>
                </View>
              </View>

              <View style={[styles.card, styles.cardRedBorder]}>
                <View style={styles.sectionHeader}>
                  <Ionicons name="warning-outline" size={16} color="#FF4A4A" />
                  <Text style={styles.sectionTitle}>Violations *</Text>
                </View>

                {noViolations ? (
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
              </View>

              
              <View style={[styles.card, styles.cardOrangeBorder]}>
                <View style={styles.sectionHeader}>
                  <Ionicons name="create-outline" size={16} color="#FFB020" />
                  <Text style={styles.sectionTitle}>Additional Notes</Text>
                </View>

                <View style={styles.notesWrap}>
                  <TextInput
                    value={notes}
                    onChangeText={setNotes}
                    placeholder="Add any additional observation or details..."
                    placeholderTextColor="rgba(255,255,255,0.35)"
                    style={styles.notesInput}
                    multiline
                    textAlignVertical="top"
                  />
                </View>
              </View>

              
              <View style={[styles.card, styles.cardGreenBorder]}>
                <View style={styles.sectionHeader}>
                  <Ionicons name="mic-outline" size={16} color="#3DDC84" />
                  <Text style={styles.sectionTitle}>Recorded Transcript</Text>
                </View>

                <View style={styles.transcriptBody}>
                  <Text style={styles.transcriptText}>{transcript}</Text>
                </View>
              </View>

              <View style={{ height: 90 }} />
            </ScrollView>

            
            <View style={styles.bottomBar}>
              <TouchableOpacity
                style={styles.finalizeBtn}
                activeOpacity={0.9}
                onPress={handleFinalize}
              >
                <Text style={styles.finalizeText}>Submit Report</Text>
              </TouchableOpacity>
            </View>

       
            <Modal
              visible={closeOpen}
              transparent
              animationType="fade"
              onRequestClose={() => setCloseOpen(false)}
            >
              <Pressable
                style={styles.modalBackdrop}
                onPress={() => setCloseOpen(false)}
              >
                <Pressable
                  style={[styles.modalCard, styles.modalGreenBorder]}
                  onPress={() => {}}
                >
                  <View style={styles.modalTopRow}>
                    <View style={styles.modalIconCircle}>
                      <Ionicons name="play" size={18} color="#3DDC84" />
                    </View>
                    <Text style={styles.modalTitleText}>
                      Start recording again?
                    </Text>
                  </View>

                  <Text style={styles.modalBodyText}>
                    Your recording will be saved as pre-submitted. You'll be able
                    to come back and finalize the submission later.
                  </Text>

                  <View style={styles.modalBtnRow}>
                    <TouchableOpacity
                      style={[styles.modalBtn, styles.modalBtnCancel]}
                      activeOpacity={0.9}
                      onPress={() => setCloseOpen(false)}
                    >
                      <Text style={styles.modalBtnCancelText}>Cancel</Text>
                    </TouchableOpacity>

                    <TouchableOpacity
                      style={[styles.modalBtn, styles.modalBtnContinue]}
                      activeOpacity={0.9}
                      onPress={confirmClose}
                    >
                      <Text style={styles.modalBtnContinueText}>Continue</Text>
                    </TouchableOpacity>
                  </View>
                </Pressable>
              </Pressable>
            </Modal>
          </View>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </LinearGradient>
  );
}


function RecordRow({ label, value }) {
  return (
    <View style={styles.recordRow}>
      <Text style={styles.recordLabel}>{label}</Text>
      <Text style={styles.recordValue} numberOfLines={1}>
        {value}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  gradient: { flex: 1 },
  safe: { flex: 1 },
  container: { flex: 1 },

  header: {
    paddingHorizontal: 16,
    paddingTop: 6,
    paddingBottom: 10,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  headerLeft: { flexDirection: "row", alignItems: "center" },
  headerIconBox: {
    width: 30,
    height: 30,
    borderRadius: 10,
    backgroundColor: "rgba(255,176,32,0.14)",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 10,
  },
  headerTitle: {
    color: "rgba(255,255,255,0.92)",
    fontSize: 13,
    fontWeight: "700",
  },
  headerSub: { color: "rgba(255,255,255,0.45)", fontSize: 11, marginTop: 2 },
  closeBtn: {
    width: 30,
    height: 30,
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.20)",
    alignItems: "center",
    justifyContent: "center",
  },
  headerDivider: {
    height: 1,
    backgroundColor: "rgba(255,176,32,0.25)",
    marginHorizontal: 16,
    marginBottom: 10,
  },

  scroll: { paddingHorizontal: 16, paddingBottom: 0 },

  card: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    padding: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    marginBottom: 12,
  },

  cardGreenBorder: { borderColor: "rgba(61,220,132,0.35)" },
  cardOrangeBorder: { borderColor: "rgba(255,176,32,0.30)" },
  cardRedBorder: { borderColor: "rgba(255,80,80,0.35)" },

  recordCard: {
    borderColor: "rgba(61,220,132,0.40)",
    backgroundColor: "rgba(0,0,0,0.20)",
  },
  recordHeader: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    marginBottom: 10,
  },
  recordTitle: { color: "#3DDC84", fontSize: 12, fontWeight: "800" },
  recordRows: { gap: 8 },
  recordRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  recordLabel: { color: "rgba(255,255,255,0.55)", fontSize: 11 },
  recordValue: {
    color: "rgba(255,255,255,0.88)",
    fontSize: 11,
    fontWeight: "700",
    textAlign: "right",
    maxWidth: "62%",
  },

  sectionHeader: { flexDirection: "row", alignItems: "center", marginBottom: 10 },
  sectionTitle: {
    marginLeft: 8,
    color: "rgba(255,255,255,0.88)",
    fontSize: 12,
    fontWeight: "700",
  },

  label: { color: "rgba(255,255,255,0.55)", fontSize: 11 },

  inputLabel: {
    color: "rgba(255,255,255,0.65)",
    fontSize: 11,
    marginBottom: 6,
  },
  inputWrap: {
    backgroundColor: "rgba(255,255,255,0.06)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    paddingHorizontal: 12,
    height: 44,
    justifyContent: "center",
  },
  input: { color: "rgba(255,255,255,0.90)", fontSize: 12 },
  locationRow: { flexDirection: "row", alignItems: "center" },

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

  notesWrap: {
    backgroundColor: "rgba(255,255,255,0.06)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    padding: 10,
    minHeight: 92,
  },
  notesInput: { color: "rgba(255,255,255,0.90)", fontSize: 12 },

  transcriptBody: {
    backgroundColor: "rgba(255,255,255,0.06)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    padding: 10,
    minHeight: 70,
  },
  transcriptText: {
    color: "rgba(255,255,255,0.70)",
    fontSize: 11,
    lineHeight: 16,
  },

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

  
  modalBackdrop: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.55)",
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 18,
  },
  modalCard: {
    width: "100%",
    maxWidth: 360,
    backgroundColor: "rgba(15,25,45,0.96)",
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
  },
  modalGreenBorder: { borderColor: "rgba(61,220,132,0.55)" },

  modalTopRow: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
    gap: 10,
  },
  modalIconCircle: {
    width: 34,
    height: 34,
    borderRadius: 12,
    backgroundColor: "rgba(61,220,132,0.12)",
    alignItems: "center",
    justifyContent: "center",
  },
  modalTitleText: {
    color: "rgba(255,255,255,0.92)",
    fontSize: 13,
    fontWeight: "800",
  },
  modalBodyText: {
    color: "rgba(255,255,255,0.55)",
    fontSize: 11,
    lineHeight: 16,
    marginBottom: 14,
  },

  modalBtnRow: { flexDirection: "row", gap: 12 },
  modalBtn: {
    flex: 1,
    height: 42,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: 1,
  },
  modalBtnCancel: {
    backgroundColor: "rgba(255,255,255,0.06)",
    borderColor: "rgba(255,255,255,0.16)",
  },
  modalBtnCancelText: {
    color: "rgba(255,255,255,0.80)",
    fontSize: 12,
    fontWeight: "800",
  },
  modalBtnContinue: {
    backgroundColor: "#1E9E5A",
    borderColor: "rgba(30,158,90,0.55)",
  },
  modalBtnContinueText: {
    color: "white",
    fontSize: 12,
    fontWeight: "900",
  },
}); 