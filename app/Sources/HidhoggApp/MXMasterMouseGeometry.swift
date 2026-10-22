import SwiftUI

enum MXMasterMouseGeometry {
    static let canvasSize = CGSize(width: 1576, height: 998)

    static let outerShell = Path { path in
        path.move(to: point(48, 626))
        path.addCurve(to: point(488, 238), control1: point(75, 541), control2: point(303, 326))
        path.addCurve(to: point(1007, 82), control1: point(671, 137), control2: point(846, 75))
        path.addCurve(to: point(1389, 289), control1: point(1153, 81), control2: point(1268, 170))
        path.addCurve(to: point(1520, 658), control1: point(1459, 358), control2: point(1495, 506))
        path.addCurve(to: point(1476, 779), control1: point(1532, 711), control2: point(1507, 756))
        path.addCurve(to: point(1065, 935), control1: point(1358, 837), control2: point(1165, 909))
        path.addCurve(to: point(923, 902), control1: point(1016, 951), control2: point(976, 937))
        path.addCurve(to: point(748, 790), control1: point(850, 855), control2: point(805, 797))
        path.addCurve(to: point(488, 868), control1: point(685, 779), control2: point(589, 839))
        path.addCurve(to: point(224, 884), control1: point(391, 897), control2: point(309, 910))
        path.addCurve(to: point(83, 754), control1: point(162, 888), control2: point(119, 817))
        path.addCurve(to: point(48, 626), control1: point(50, 699), control2: point(34, 658))
        path.closeSubpath()
    }

    static let lowerShell = Path { path in
        path.move(to: point(820, 403))
        path.addCurve(to: point(359, 822), control1: point(708, 500), control2: point(478, 723))
        path.addCurve(to: point(224, 884), control1: point(310, 863), control2: point(269, 883))
        path.addCurve(to: point(488, 868), control1: point(314, 909), control2: point(400, 893))
        path.addCurve(to: point(748, 790), control1: point(589, 839), control2: point(685, 779))
        path.addCurve(to: point(818, 827), control1: point(775, 793), control2: point(797, 808))
        path.addLine(to: point(880, 835))
        path.closeSubpath()
    }

    static let sideWall = Path { path in
        path.move(to: point(1389, 289))
        path.addCurve(to: point(1520, 658), control1: point(1459, 358), control2: point(1495, 506))
        path.addCurve(to: point(1476, 779), control1: point(1532, 711), control2: point(1507, 756))
        path.addCurve(to: point(1421, 360), control1: point(1473, 641), control2: point(1455, 462))
        path.addCurve(to: point(1389, 289), control1: point(1410, 327), control2: point(1400, 305))
        path.closeSubpath()
    }

    static let topShell = Path { path in
        path.move(to: point(1172, 119))
        path.addCurve(to: point(1389, 289), control1: point(1261, 173), control2: point(1331, 232))
        path.addCurve(to: point(1455, 519), control1: point(1428, 348), control2: point(1444, 422))
        path.addCurve(to: point(1476, 779), control1: point(1466, 615), control2: point(1472, 708))
        path.addCurve(to: point(1065, 923), control1: point(1362, 830), control2: point(1174, 895))
        path.addCurve(to: point(951, 900), control1: point(1028, 935), control2: point(996, 928))
        path.addCurve(to: point(748, 728), control1: point(865, 849), control2: point(791, 786))
        path.addCurve(to: point(755, 650), control1: point(725, 699), control2: point(732, 673))
        path.addCurve(to: point(1182, 322), control1: point(857, 552), control2: point(1064, 421))
        path.addCurve(to: point(1212, 205), control1: point(1218, 291), control2: point(1233, 249))
        path.addCurve(to: point(1172, 119), control1: point(1204, 177), control2: point(1186, 142))
        path.closeSubpath()
    }

    static let bandShadow = Path { path in
        path.move(to: point(1158, 179))
        path.addCurve(to: point(1217, 237), control1: point(1183, 190), control2: point(1211, 201))
        path.addCurve(to: point(1175, 335), control1: point(1223, 277), control2: point(1204, 310))
        path.addLine(to: point(895, 536))
        path.addCurve(to: point(748, 655), control1: point(831, 582), control2: point(773, 625))
        path.addCurve(to: point(758, 739), control1: point(725, 683), control2: point(735, 710))
        path.addCurve(to: point(951, 900), control1: point(808, 798), control2: point(885, 862))
        path.addCurve(to: point(1065, 923), control1: point(995, 927), control2: point(1028, 935))
        path.addCurve(to: point(1476, 779), control1: point(1174, 895), control2: point(1362, 830))
        path.addCurve(to: point(1065, 935), control1: point(1358, 837), control2: point(1165, 909))
        path.addCurve(to: point(944, 914), control1: point(1026, 947), control2: point(990, 940))
        path.addCurve(to: point(733, 737), control1: point(866, 867), control2: point(787, 798))
        path.addCurve(to: point(721, 644), control1: point(697, 698), control2: point(699, 671))
        path.addCurve(to: point(890, 503), control1: point(758, 598), control2: point(837, 543))
        path.addLine(to: point(1148, 319))
        path.addCurve(to: point(1189, 239), control1: point(1181, 295), control2: point(1198, 273))
        path.addCurve(to: point(1158, 179), control1: point(1183, 212), control2: point(1172, 190))
        path.closeSubpath()
    }

    static let rightClickPanel = Path { path in
        path.move(to: point(1004, 274))
        path.addCurve(to: point(1141, 198), control1: point(1056, 236), control2: point(1117, 197))
        path.addCurve(to: point(1187, 243), control1: point(1168, 194), control2: point(1183, 218))
        path.addCurve(to: point(1148, 319), control1: point(1194, 272), control2: point(1176, 296))
        path.addLine(to: point(1072, 373))
        path.addCurve(to: point(1004, 274), control1: point(1057, 337), control2: point(1034, 297))
        path.closeSubpath()
    }

    static let panelSeams = Path { path in
        path.move(to: point(488, 238))
        path.addCurve(to: point(539, 270), control1: point(510, 246), control2: point(543, 259))
        path.addLine(to: point(397, 390))
        path.move(to: point(83, 754))
        path.addLine(to: point(525, 343))
        path.addCurve(to: point(612, 312), control1: point(552, 319), control2: point(582, 306))
        path.addCurve(to: point(813, 388), control1: point(691, 319), control2: point(772, 345))
        path.addCurve(to: point(832, 425), control1: point(822, 397), control2: point(826, 411))
    }

    static let palmRest = Path { path in
        path.move(to: point(813, 388))
        path.addLine(to: point(832, 405))
        path.addCurve(to: point(359, 822), control1: point(681, 538), control2: point(489, 725))
        path.addCurve(to: point(224, 884), control1: point(309, 861), control2: point(266, 883))
        path.addCurve(to: point(160, 862), control1: point(193, 888), control2: point(177, 877))
        path.addCurve(to: point(359, 811), control1: point(225, 894), control2: point(289, 868))
        path.closeSubpath()
    }

    static let modeButton = Path { path in
        path.move(to: point(640, 224))
        path.addLine(to: point(671, 233))
        path.addLine(to: point(587, 301))
        path.addCurve(to: point(560, 297), control1: point(580, 307), control2: point(571, 304))
        path.addCurve(to: point(562, 285), control1: point(556, 294), control2: point(556, 290))
        path.closeSubpath()
    }

    static let verticalWheelHousing = Path { path in
        path.move(to: point(426, 377))
        path.addLine(to: point(477, 399))
        path.addCurve(to: point(271, 602), control1: point(458, 421), control2: point(300, 576))
        path.addLine(to: point(233, 570))
        path.addCurve(to: point(390, 393), control1: point(250, 485), control2: point(312, 404))
        path.closeSubpath()
    }

    static let verticalWheelFace = Path { path in
        path.move(to: point(427, 396))
        path.addCurve(to: point(273, 509), control1: point(368, 390), control2: point(303, 445))
        path.addCurve(to: point(255, 570), control1: point(258, 538), control2: point(253, 558))
        path.addLine(to: point(280, 590))
        path.addLine(to: point(459, 414))
        path.addCurve(to: point(427, 396), control1: point(448, 404), control2: point(438, 398))
        path.closeSubpath()
    }

    static let verticalWheelShadow = Path { path in
        path.move(to: point(459, 414))
        path.addCurve(to: point(304, 530), control1: point(395, 404), control2: point(329, 465))
        path.addCurve(to: point(294, 576), control1: point(296, 549), control2: point(293, 565))
        path.addLine(to: point(280, 590))
        path.closeSubpath()
    }

    static let thumbWheelCasing = Path { path in
        path.move(to: point(832, 405))
        path.addLine(to: point(1004, 274))
        path.addCurve(to: point(1072, 373), control1: point(1034, 297), control2: point(1057, 337))
        path.addLine(to: point(884, 502))
        path.addCurve(to: point(832, 405), control1: point(874, 460), control2: point(855, 428))
        path.closeSubpath()
    }

    static let thumbWheelUpperFace = Path { path in
        path.move(to: point(925, 338))
        path.addLine(to: point(995, 286))
        path.addLine(to: point(1010, 292))
        path.addLine(to: point(1047, 339))
        path.addCurve(to: point(1053, 379), control1: point(1052, 352), control2: point(1057, 369))
        path.addLine(to: point(976, 433))
        path.addLine(to: point(963, 395))
        path.closeSubpath()
    }

    static let thumbWheelUpperHighlight = Path { path in
        path.move(to: point(934, 346))
        path.addLine(to: point(1010, 292))
        path.addCurve(to: point(1047, 339), control1: point(1027, 307), control2: point(1040, 324))
        path.addLine(to: point(969, 396))
        path.addCurve(to: point(934, 346), control1: point(960, 377), control2: point(947, 358))
        path.closeSubpath()
    }

    static let thumbWheelLowerFace = Path { path in
        path.move(to: point(832, 405))
        path.addLine(to: point(911, 349))
        path.addLine(to: point(921, 355))
        path.addCurve(to: point(962, 443), control1: point(942, 376), control2: point(958, 403))
        path.addLine(to: point(885, 497))
        path.addCurve(to: point(832, 405), control1: point(878, 460), control2: point(858, 423))
        path.closeSubpath()
    }

    static let thumbWheelLowerHighlight = Path { path in
        path.move(to: point(842, 412))
        path.addLine(to: point(921, 355))
        path.addCurve(to: point(957, 405), control1: point(938, 372), control2: point(950, 389))
        path.addLine(to: point(877, 462))
        path.addCurve(to: point(842, 412), control1: point(868, 441), control2: point(854, 422))
        path.closeSubpath()
    }

    static let backButton = Path { path in
        path.move(to: point(1010, 477))
        path.addLine(to: point(1117, 402))
        path.addCurve(to: point(1133, 412), control1: point(1128, 394), control2: point(1135, 399))
        path.addCurve(to: point(1107, 449), control1: point(1131, 427), control2: point(1120, 439))
        path.addLine(to: point(1024, 507))
        path.closeSubpath()
    }

    static let forwardButton = Path { path in
        path.move(to: point(988, 492))
        path.addLine(to: point(999, 517))
        path.addCurve(to: point(979, 543), control1: point(1001, 526), control2: point(990, 535))
        path.addLine(to: point(900, 599))
        path.addCurve(to: point(869, 596), control1: point(886, 609), control2: point(870, 608))
        path.addCurve(to: point(890, 565), control1: point(867, 584), control2: point(878, 574))
        path.closeSubpath()
    }

    static let smoothBand = Path { path in
        path.move(to: point(826, 397))
        path.addCurve(to: point(997, 267), control1: point(885, 351), control2: point(944, 309))
        path.addCurve(to: point(1140, 186), control1: point(1050, 228), control2: point(1113, 188))
        path.addCurve(to: point(1201, 242), control1: point(1176, 180), control2: point(1197, 207))
        path.addCurve(to: point(1157, 332), control1: point(1208, 280), control2: point(1188, 307))
        path.addLine(to: point(1078, 386))
    }

    static let verticalWheelHitRegion = Path { path in
        path.addPath(verticalWheelFace)
        path.addPath(verticalWheelShadow)
    }
    static let verticalWheelHitBounds = verticalWheelHitRegion.boundingRect
    static let verticalWheelHitShape = verticalWheelHitRegion.applying(
        CGAffineTransform(translationX: -verticalWheelHitBounds.minX, y: -verticalWheelHitBounds.minY)
    )
    static let thumbWheelHitBounds = thumbWheelCasing.boundingRect
    static let thumbWheelHitShape = thumbWheelCasing.applying(
        CGAffineTransform(translationX: -thumbWheelHitBounds.minX, y: -thumbWheelHitBounds.minY)
    )
    static let backButtonHitBounds = backButton.boundingRect
    static let backButtonHitShape = backButton.applying(
        CGAffineTransform(translationX: -backButtonHitBounds.minX, y: -backButtonHitBounds.minY)
    )
    static let forwardButtonHitBounds = forwardButton.boundingRect
    static let forwardButtonHitShape = forwardButton.applying(
        CGAffineTransform(translationX: -forwardButtonHitBounds.minX, y: -forwardButtonHitBounds.minY)
    )

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
