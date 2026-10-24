import type { ComponentType } from "react";
import {
  BookingsIcon,
  ExpensesIcon,
  type IconProps,
  RecurringIcon,
  SettingsIcon,
} from "./components/icons";

// The navigation entries of the app shell.
export const NAV: {
  path: string;
  label: string;
  icon: ComponentType<IconProps>;
}[] = [
  { path: "/bookings", label: "Bookings", icon: BookingsIcon },
  { path: "/expenses", label: "Expenses", icon: ExpensesIcon },
  { path: "/recurring", label: "Recurring", icon: RecurringIcon },
  { path: "/settings", label: "Settings", icon: SettingsIcon },
];
