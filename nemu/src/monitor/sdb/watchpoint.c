/***************************************************************************************
 * Copyright (c) 2014-2022 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#include "sdb.h"
#include <debug.h>

#define NR_WP 32

typedef struct watchpoint
{
  int NO;
  struct watchpoint *next;

  /* TODO: Add more members if necessary */
  struct watchpoint *next_alloc;
  struct watchpoint *prev_alloc;
  bool alloc;
  char str[32];
  word_t v;

} WP;

static WP wp_pool[NR_WP] = {};
static WP *head = NULL, *free_ = NULL;

void init_wp_pool()
{
  int i;
  for (i = 0; i < NR_WP; i++)
  {
    wp_pool[i].NO = i;
    wp_pool[i].next = (i == NR_WP - 1 ? NULL : &wp_pool[i + 1]);
    wp_pool[i].next_alloc = NULL;
    wp_pool[i].prev_alloc = NULL;
  }

  head = NULL;
  free_ = wp_pool;
}

/* TODO: Implement the functionality of watchpoint */

WP *new_wp()
{
  Assert(free_ != NULL, "wp_pool is full");
  WP *p = free_;
  free_ = free_->next;
  p->next_alloc = head;
  p->prev_alloc = NULL;
  if (head != NULL)
  {
    head->prev_alloc = p;
  }
  head = p;
  return p;
}

void free_wp(WP *wp)
{
  if (wp != head && wp->prev_alloc != NULL)
  {
    wp->prev_alloc->next_alloc = wp->next_alloc;
  }
  else
  {
    head = wp->next_alloc;
  }
  wp->next = free_;
  wp->prev_alloc = NULL;
  wp->next_alloc = NULL;
  wp->alloc = false;
  free_ = wp;
}

void wp_add(const char *e, bool *success)
{
  WP *p = new_wp();
  p->alloc = true;
  strncpy(p->str, e, 32);
  word_t v = expr(p->str, success);
  if (*success)
  {
    p->v = v;
  }
  else
  {
    free_wp(p);
  }
}

void wp_show()
{
  bool success;
  for (WP *p = head; p != NULL; p = p->next_alloc)
  {
    word_t v = expr(p->str, &success);
    p->v = v;
    printf("%02d\t\"%s\"\t: 0x%016llx, %020llu\n", p->NO, p->str, v, v);
  }
}

void wp_del(int id, bool *success)
{
  if (id < 0 || id > sizeof(wp_pool) / sizeof(WP) || !wp_pool[id].alloc)
  {
    *success = false;
    return;
  }
  *success = true;
  free_wp(&wp_pool[id]);
}

bool wp_check_changed()
{
  bool success;
  for (WP *p = head; p != NULL; p = p->next_alloc)
  {
    word_t v = expr(p->str, &success);
    if (p->v != v)
    {
      printf("%02d\t\"%s\"\t: old 0x%016llx, new 0x%016llx\n", p->NO, p->str, p->v, v);
      p->v = v;
      return true;
    }
  }
  return false;
}