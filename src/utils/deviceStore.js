import AsyncStorage from "@react-native-async-storage/async-storage";

const KEY = "EVVOS_DEVICE_PAIRED";

export async function getPaired() {
  const v = await AsyncStorage.getItem(KEY);
  return v === "1";
}

export async function setPaired(value) {
  await AsyncStorage.setItem(KEY, value ? "1" : "0");
}

export async function clearPaired() {
  await AsyncStorage.removeItem(KEY);
}