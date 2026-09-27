import 'package:hive_ce/hive.dart';

import 'music_document.dart';
import 'music_page.dart';
import 'stroke.dart';

/// hive_ce 用の手書きアダプタ (build_runner 不要)。
class MusicDocumentAdapter extends TypeAdapter<MusicDocument> {
  @override
  final int typeId = 1;

  @override
  MusicDocument read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(reader.readMap());
    return MusicDocument(
      id: map['id'] as String,
      title: map['title'] as String? ?? '無題の教材',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
      pageCount: (map['pageCount'] as num?)?.toInt() ?? 0,
      coverThumbPath: map['coverThumbPath'] as String?,
      tags: (map['tags'] as List<dynamic>? ?? const <dynamic>[])
          .map((e) => e as String)
          .toList(),
    );
  }

  @override
  void write(BinaryWriter writer, MusicDocument obj) {
    writer.writeMap(<String, dynamic>{
      'id': obj.id,
      'title': obj.title,
      'createdAt': obj.createdAt,
      'updatedAt': obj.updatedAt,
      'pageCount': obj.pageCount,
      'coverThumbPath': obj.coverThumbPath,
      'tags': obj.tags,
    });
  }
}

class MusicPageAdapter extends TypeAdapter<MusicPage> {
  @override
  final int typeId = 2;

  @override
  MusicPage read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(reader.readMap());
    final strokes = (map['strokes'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => Stroke.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    return MusicPage(
      id: map['id'] as String,
      documentId: map['documentId'] as String,
      index: (map['index'] as num?)?.toInt() ?? 0,
      imagePath: map['imagePath'] as String,
      thumbPath: map['thumbPath'] as String,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
      strokes: strokes,
      note: map['note'] as String? ?? '',
    );
  }

  @override
  void write(BinaryWriter writer, MusicPage obj) {
    writer.writeMap(<String, dynamic>{
      'id': obj.id,
      'documentId': obj.documentId,
      'index': obj.index,
      'imagePath': obj.imagePath,
      'thumbPath': obj.thumbPath,
      'width': obj.width,
      'height': obj.height,
      'updatedAt': obj.updatedAt,
      'strokes': <Map<String, dynamic>>[
        for (final s in obj.strokes) s.toMap(),
      ],
      'note': obj.note,
    });
  }
}
